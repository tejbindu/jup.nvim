-- Manages the Python kernel bridge process (one per notebook buffer).
-- Communicates via stdin/stdout newline-delimited JSON.

local M = {}

local config = require("jup.config")
local output = require("jup.output")

-- Per-buffer state
-- [bufnr] = { job_id, line_buf, request_id, pending, cell_outputs, cell_indices, on_done_cb }
local _state = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function bridge_script()
  local src = debug.getinfo(1, "S").source:sub(2)
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

local function send_msg(bufnr, msg)
  local st = get(bufnr)
  if not st then return end
  local line = vim.fn.json_encode(msg) .. "\n"
  vim.fn.chansend(st.job_id, line)
end

-- ── Message receive ───────────────────────────────────────────────────────────

local function on_stdout(bufnr, data)
  local st = get(bufnr)
  if not st then return end

  st.line_buf = (st.line_buf or "") .. table.concat(data, "\n")
  local lines = vim.split(st.line_buf, "\n", { plain = true })
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

  if not st.cell_outputs[cell_id] then
    st.cell_outputs[cell_id] = {}
  end

  -- Merge consecutive stream chunks of the same name
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

  local cell_index = st.cell_indices[cell_id]
  if not cell_index then return end

  -- Update cells_meta so save() round-trips the structured outputs correctly.
  -- Lazy require to avoid circular dependency (buffer -> kernel -> buffer).
  local buf_mod = require("jup.buffer")
  buf_mod.update_cell_outputs(bufnr, cell_index, st.cell_outputs[cell_id])

  -- Re-render the output block in the buffer
  local text_lines = output.format_output_lines(st.cell_outputs[cell_id])
  output.set_output_block(bufnr, cell_index, text_lines)
end

function M._on_status() end

function M._on_exec_count(bufnr, cell_id, count)
  local st = get(bufnr)
  if not st then return end
  local cell_index = st.cell_indices[cell_id]
  if cell_index then
    output.set_exec_count(bufnr, cell_index, count)
  end
end

function M._on_done(bufnr, cell_id, status)
  local st = get(bufnr)
  if not st then return end
  local cell_index = st.cell_indices[cell_id]
  if cell_index then
    output.set_running(bufnr, cell_index, false)
  end
  if st.on_done_cb then
    st.on_done_cb(cell_id, status)
    st.on_done_cb = nil
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Start a bridge process for `bufnr`. Returns error string or nil.
function M.start(bufnr)
  if get(bufnr) then return nil end

  local cfg    = config.get()
  local python = cfg.python_path
  local script = bridge_script()

  if vim.fn.filereadable(script) == 0 then
    return "bridge script not found: " .. script
  end

  local job_id = vim.fn.jobstart({ python, script }, {
    on_stdout = function(_, data, _) on_stdout(bufnr, data) end,
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
    job_id       = job_id,
    line_buf     = "",
    request_id   = 0,
    pending      = {},
    cell_outputs = {},   -- cell_id -> list of output objects
    cell_indices = {},   -- cell_id -> 1-based cell_index (stable across row shifts)
    on_done_cb   = nil,
  }
  return nil
end

--- Stop the bridge process for `bufnr`.
function M.stop(bufnr)
  local st = get(bufnr)
  if not st then return end
  pcall(vim.fn.jobstop, st.job_id)
  _state[bufnr] = nil
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
---@param cell_id string   routing ID for this execution
---@param code string
---@param cell_index integer  1-based index; stable key used to place output
---@param callback function(err)|nil
function M.execute(bufnr, cell_id, code, cell_index, callback)
  local st = get(bufnr)
  if not st then
    vim.notify("[jup.nvim] no kernel connected — use :JupConnect", vim.log.levels.WARN)
    return
  end

  st.cell_outputs[cell_id] = {}
  st.cell_indices[cell_id] = cell_index

  output.clear_output_block(bufnr, cell_index)
  output.set_running(bufnr, cell_index, true)

  st.on_done_cb = function(_, status)
    if callback then
      callback(status == "ok" and nil or ("execution failed: " .. (status or "")))
    end
  end

  M.request(bufnr, "execute", { code = code, cell_id = cell_id }, function(err, _)
    if err then
      output.set_running(bufnr, cell_index, false)
      vim.notify("[jup.nvim] execute error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

--- Interrupt the running kernel.
function M.interrupt(bufnr, callback)
  M.request(bufnr, "interrupt", {}, callback)
end

--- Restart the kernel and clear all outputs.
function M.restart(bufnr, callback)
  local st = get(bufnr)
  if st then
    st.cell_outputs = {}
    st.cell_indices = {}
    output.clear_all_output_blocks(bufnr)
  end
  M.request(bufnr, "restart", {}, callback)
end

--- Get kernel info.
function M.kernel_info(bufnr, callback)
  M.request(bufnr, "kernel_info", {}, callback)
end

--- Clear output for a single cell by its 1-based index.
function M.clear_cell_output(bufnr, cell_index)
  output.clear_output_block(bufnr, cell_index)
  local st = get(bufnr)
  if st then
    for cell_id, idx in pairs(st.cell_indices) do
      if idx == cell_index then
        st.cell_outputs[cell_id] = {}
        break
      end
    end
  end
  local buf_mod = require("jup.buffer")
  buf_mod.update_cell_outputs(bufnr, cell_index, {})
end

--- Clear all outputs for a buffer.
function M.clear_outputs(bufnr)
  local st = get(bufnr)
  if st then
    st.cell_outputs = {}
    st.cell_indices = {}
    output.clear_all_output_blocks(bufnr)
  end
end

return M
