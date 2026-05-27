-- Manages the Python kernel bridge process (one per notebook buffer).
-- Communicates via stdin/stdout newline-delimited JSON.

local M = {}

local config  = require("jup.config")
local output  = require("jup.output")

-- Per-buffer state
-- [bufnr] = { job_id, line_buf, request_id, pending, output_handlers, cell_outputs }
local _state = {}

-- Extmark IDs for outputs restored from disk at load time, not from kernel execution.
-- Stored separately because kernel._state doesn't exist yet at restore time.
-- [bufnr][cell_id] = extmark_id
local _restored_extmarks = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function bridge_script()
  -- Resolve path relative to this file: lua/jup/kernel.lua → python/jup_kernel.py
  local src = debug.getinfo(1, "S").source:sub(2)          -- strip leading @
  return vim.fn.fnamemodify(src, ":h:h:h") .. "/python/jup_kernel.py"
end

local function get(bufnr)
  return _state[bufnr]
end

local function next_id(st)
  st.request_id = (st.request_id or 0) + 1
  return st.request_id
end

-- ── Message send ─────────────────────────────────────────────────────────────

--- Send a JSON message to the bridge stdin.
local function send_msg(bufnr, msg)
  local st = get(bufnr)
  if not st then return end
  local line = vim.fn.json_encode(msg) .. "\n"
  vim.fn.chansend(st.job_id, line)
end

-- ── Message receive ───────────────────────────────────────────────────────────

-- Called when stdout data arrives from the bridge (may be partial lines).
local function on_stdout(bufnr, data)
  local st = get(bufnr)
  if not st then return end

  -- Append to incomplete-line buffer and split on newlines
  st.line_buf = (st.line_buf or "") .. table.concat(data, "\n")
  local lines = vim.split(st.line_buf, "\n", { plain = true })
  -- Last element is the incomplete trailing fragment (may be "")
  st.line_buf = table.remove(lines)

  for _, raw in ipairs(lines) do
    raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if raw ~= "" then
      local ok, msg = pcall(vim.fn.json_decode, raw)
      if ok and type(msg) == "table" then
        vim.schedule(function() M._dispatch(bufnr, msg) end)
      end
    end
  end
end

--- Route an incoming bridge message to the right handler.
function M._dispatch(bufnr, msg)
  local st = get(bufnr)
  if not st then return end
  local t = msg.type or ""

  if t == "result" then
    -- Reply to a request we sent
    local cb = st.pending[msg.id]
    if cb then
      st.pending[msg.id] = nil
      cb(msg.error, msg.data)
    end

  elseif t == "output" then
    M._on_output(bufnr, msg.cell_id, msg.output)

  elseif t == "status" then
    M._on_status(bufnr, msg.cell_id, msg.execution_state)

  elseif t == "execution_count" then
    M._on_exec_count(bufnr, msg.cell_id, msg.count)

  elseif t == "done" then
    M._on_done(bufnr, msg.cell_id, msg.status)

  elseif t == "log" then
    local level = msg.level or "info"
    if level == "error" then
      vim.notify("[jup.nvim] " .. (msg.message or ""), vim.log.levels.ERROR)
    elseif level == "warn" then
      vim.notify("[jup.nvim] " .. (msg.message or ""), vim.log.levels.WARN)
    else
      vim.notify("[jup.nvim] " .. (msg.message or ""), vim.log.levels.INFO)
    end
  end
end

-- ── Kernel output handlers ───────────────────────────────────────────────────

function M._on_output(bufnr, cell_id, out)
  local st = get(bufnr)
  if not st then return end

  -- Accumulate outputs keyed by cell_id
  if not st.cell_outputs[cell_id] then
    st.cell_outputs[cell_id] = {}
  end
  -- Merge stream chunks into the existing stream output for that name
  if out.output_type == "stream" then
    local last = st.cell_outputs[cell_id][#st.cell_outputs[cell_id]]
    if last and last.output_type == "stream" and last.name == out.name then
      last.text = (last.text or "") .. (out.text or "")
    else
      table.insert(st.cell_outputs[cell_id], vim.deepcopy(out))
    end
  else
    table.insert(st.cell_outputs[cell_id], vim.deepcopy(out))
  end

  -- Re-render output for this cell
  local anchor = st.cell_anchors[cell_id]
  if anchor then
    local eid = st.output_extmarks[cell_id]
    local new_eid = output.set_cell_output(bufnr, anchor, st.cell_outputs[cell_id], eid)
    st.output_extmarks[cell_id] = new_eid
  end
end

function M._on_status() end

function M._on_exec_count(bufnr, cell_id, count)
  local st = get(bufnr)
  if not st then return end
  local anchor = st.cell_anchors[cell_id]
  if anchor then
    -- anchor here is the end_row; sep_row stored separately
    local sep = st.cell_sep_rows[cell_id]
    if sep then
      output.set_exec_count(bufnr, sep, count)
    end
  end
end

function M._on_done(bufnr, cell_id, status)
  local st = get(bufnr)
  if not st then return end
  local sep = st.cell_sep_rows[cell_id]
  if sep then
    output.set_running(bufnr, sep, false)
    if status == "error" then
      -- leave output visible (already rendered)
    end
  end
  if st.on_done_cb then
    st.on_done_cb(cell_id, status)
    st.on_done_cb = nil
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Start a bridge process for `bufnr`. Returns error string or nil.
function M.start(bufnr)
  if get(bufnr) then
    return nil  -- already running
  end

  local cfg    = config.get()
  local python = cfg.python_path
  local script = bridge_script()

  if vim.fn.filereadable(script) == 0 then
    return "bridge script not found: " .. script
  end

  local job_id = vim.fn.jobstart({ python, script }, {
    on_stdout = function(_, data, _)
      on_stdout(bufnr, data)
    end,
    on_stderr = function(_, data, _)
      local msg = table.concat(data or {}, "")
      if msg:gsub("%s", "") ~= "" then
        vim.schedule(function()
          vim.notify("[jup.nvim bridge stderr] " .. msg, vim.log.levels.WARN)
        end)
      end
    end,
    on_exit = function(_, code, _)
      _state[bufnr] = nil
      if code ~= 0 then
        vim.schedule(function()
          vim.notify("[jup.nvim] kernel bridge exited with code " .. code, vim.log.levels.WARN)
        end)
      end
    end,
    stdout_buffered = false,
    stderr_buffered = false,
  })

  if job_id <= 0 then
    return "failed to start bridge process (is python3 in PATH?)"
  end

  _state[bufnr] = {
    job_id         = job_id,
    line_buf       = "",
    request_id     = 0,
    pending        = {},     -- id -> callback
    cell_outputs   = {},     -- cell_id -> list of output objects
    output_extmarks= {},     -- cell_id -> extmark_id
    cell_anchors   = {},     -- cell_id -> anchor_row (end of cell)
    cell_sep_rows  = {},     -- cell_id -> sep_row
    on_done_cb     = nil,
  }
  return nil
end

--- Stop the bridge process for `bufnr`.
function M.stop(bufnr)
  local st = get(bufnr)
  if not st then return end
  pcall(vim.fn.jobstop, st.job_id)
  _state[bufnr] = nil
  _restored_extmarks[bufnr] = nil
end

--- Register an extmark ID that was placed at load time (not from kernel execution).
--- Called from buffer._restore_outputs so kernel.execute can clear it on re-run.
function M.register_restored_extmark(bufnr, cell_id, eid)
  if not _restored_extmarks[bufnr] then
    _restored_extmarks[bufnr] = {}
  end
  _restored_extmarks[bufnr][cell_id] = eid
end

--- Return true if a bridge is running for `bufnr`.
function M.is_running(bufnr)
  return get(bufnr) ~= nil
end

--- Send an RPC request; callback receives (err, data).
function M.request(bufnr, method, params, callback)
  local st = get(bufnr)
  if not st then
    if callback then callback("kernel bridge not started", nil) end
    return
  end
  local id = next_id(st)
  st.pending[id] = callback or function() end
  send_msg(bufnr, { id = id, method = method, params = params or {} })
end

--- Start or connect to a kernel.
---@param bufnr integer
---@param opts table  {kernel_name?=, connection_file?=}
---@param callback function(err, data)
function M.connect(bufnr, opts, callback)
  opts = opts or {}
  local err = M.start(bufnr)
  if err then
    if callback then callback(err, nil) end
    return
  end

  if opts.connection_file then
    M.request(bufnr, "connect", { connection_file = opts.connection_file }, callback)
  else
    local cfg = config.get()
    M.request(bufnr, "start_kernel", {
      kernel_name = opts.kernel_name or cfg.kernel.default,
    }, callback)
  end
end

--- Execute a cell.
---@param bufnr integer
---@param cell_id string   unique ID for this cell execution (used to route outputs)
---@param code string
---@param sep_row integer  0-indexed separator row (for UI updates)
---@param anchor_row integer  0-indexed last row of cell (for output placement)
---@param callback function(err)|nil  called when execution completes
function M.execute(bufnr, cell_id, code, sep_row, anchor_row, callback)
  local st = get(bufnr)
  if not st then
    vim.notify("[jup.nvim] no kernel connected — use :JupConnect", vim.log.levels.WARN)
    return
  end

  -- Reset state for this cell
  st.cell_outputs[cell_id]    = {}
  st.cell_anchors[cell_id]    = anchor_row
  st.cell_sep_rows[cell_id]   = sep_row

  -- Clear previous output: either from a prior execution or restored from disk
  local prev_eid = st.output_extmarks[cell_id]
  if not prev_eid and _restored_extmarks[bufnr] then
    prev_eid = _restored_extmarks[bufnr][cell_id]
    _restored_extmarks[bufnr][cell_id] = nil
  end
  output.clear_cell_output(bufnr, prev_eid)
  st.output_extmarks[cell_id] = nil

  output.set_running(bufnr, sep_row, true)

  st.on_done_cb = function(_, status)
    output.set_running(bufnr, sep_row, false)
    if callback then callback(status == "ok" and nil or ("execution failed: " .. (status or ""))) end
  end

  M.request(bufnr, "execute", { code = code, cell_id = cell_id }, function(err, _)
    if err then
      output.set_running(bufnr, sep_row, false)
      vim.notify("[jup.nvim] execute error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

--- Interrupt the running kernel.
function M.interrupt(bufnr, callback)
  M.request(bufnr, "interrupt", {}, callback)
end

--- Restart the kernel.
function M.restart(bufnr, callback)
  local st = get(bufnr)
  if st then
    st.cell_outputs    = {}
    st.output_extmarks = {}
    st.cell_anchors    = {}
    st.cell_sep_rows   = {}
    output.clear_all_outputs(bufnr)
  end
  M.request(bufnr, "restart", {}, callback)
end

--- Get kernel info.
function M.kernel_info(bufnr, callback)
  M.request(bufnr, "kernel_info", {}, callback)
end

--- Return the list of output objects accumulated for a cell, or nil.
function M.get_cell_outputs(bufnr, cell_id)
  local st = get(bufnr)
  return st and st.cell_outputs[cell_id]
end

--- Clear output for a single cell by its exec id.
function M.clear_cell_output(bufnr, cell_id)
  local st = get(bufnr)
  if not st then return end
  output.clear_cell_output(bufnr, st.output_extmarks[cell_id])
  st.cell_outputs[cell_id]    = {}
  st.output_extmarks[cell_id] = nil
end

--- Clear all outputs for a buffer.
function M.clear_outputs(bufnr)
  local st = get(bufnr)
  if st then
    st.cell_outputs    = {}
    st.output_extmarks = {}
    output.clear_all_outputs(bufnr)
  end
end

return M
