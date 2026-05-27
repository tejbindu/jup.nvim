-- Manages the notebook buffer lifecycle:
--   BufReadCmd  → parse .ipynb → write cell format → insert output blocks → set up extmarks
--   BufWriteCmd → parse buffer (strips output blocks) → serialize .ipynb → write file
--   BufWipeout  → clean up kernel

local M = {}

local notebook = require("jup.notebook")
local output   = require("jup.output")
local kernel   = require("jup.kernel")
local config   = require("jup.config")

-- Per-buffer state: [bufnr] = { path, nb_meta, nb_cells_meta, filetype }
-- nb_cells_meta: list of { id, metadata, outputs, execution_count } preserved from .ipynb
local _state = {}

-- ── Initialization ────────────────────────────────────────────────────────────

--- Load an .ipynb file into `bufnr`.
---@param bufnr integer
---@param path string  path to .ipynb file (resolved to absolute internally)
function M.load(bufnr, path)
  if _state[bufnr] then return end

  path = vim.fn.fnamemodify(path, ":p")

  local raw = M._read_file(path)

  if not raw or raw == "" then
    M._scaffold(bufnr, path)
    return
  end

  local ok, nb = pcall(notebook.parse_ipynb, raw)
  if not ok then
    vim.notify("[jup.nvim] " .. tostring(nb), vim.log.levels.ERROR)
    return
  end

  local cells_meta = {}
  for _, c in ipairs(nb.cells) do
    table.insert(cells_meta, {
      id              = c.id,
      metadata        = c.metadata,
      outputs         = c.outputs,
      execution_count = c.execution_count,
    })
  end

  _state[bufnr] = {
    path           = path,
    nb_meta        = nb.metadata,
    nbformat       = nb.nbformat,
    nbformat_minor = nb.nbformat_minor,
    cells_meta     = cells_meta,
  }

  -- Disable swap file before writing: .ipynb is managed entirely by jup
  -- (BufWriteCmd handles saves), so a swap file serves no purpose and its
  -- presence triggers E325 when nvim_buf_set_lines is called.
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buftype  = "acwrite"

  local lines = notebook.notebook_to_lines(nb)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false

  M._set_filetype(bufnr, nb.metadata)

  output.setup_highlights()

  -- Insert saved output blocks BEFORE decorating so borders land at correct rows
  M._restore_outputs(bufnr, nb.cells)
  output.decorate_separators(bufnr)

  require("jup")._apply_keymaps(bufnr)
  M._attach_autocmds(bufnr)
end

--- Save buffer contents back to the .ipynb file.
---@param bufnr integer
function M.save(bufnr)
  local st = _state[bufnr]
  if not st then
    vim.notify("[jup.nvim] buffer state lost — try reopening the file", vim.log.levels.WARN)
    return
  end

  local lines  = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local parsed = notebook.lines_to_cells(lines)

  -- Build full cell list merging current source with saved metadata (outputs, ids, etc.)
  local full_cells = {}
  for i, pc in ipairs(parsed) do
    local meta = st.cells_meta[i] or {}
    table.insert(full_cells, {
      id              = meta.id or M._new_cell_id(i),
      cell_type       = pc.cell_type,
      source          = pc.source,
      metadata        = meta.metadata or {},
      outputs         = meta.outputs or {},
      execution_count = meta.execution_count,
    })
  end

  local nb = {
    metadata       = st.nb_meta or {},
    nbformat       = st.nbformat or 4,
    nbformat_minor = st.nbformat_minor or 5,
    cells          = full_cells,
  }

  local ok, json = pcall(notebook.serialize_ipynb, nb)
  if not ok then
    vim.notify("[jup.nvim] serialize error: " .. tostring(json), vim.log.levels.ERROR)
    return
  end

  local pretty = M._pretty_json(json)

  local f, err = io.open(st.path, "w")
  if not f then
    vim.notify("[jup.nvim] cannot write " .. st.path .. ": " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  f:write(pretty)
  f:close()

  vim.bo[bufnr].modified = false
  vim.notify("[jup.nvim] saved " .. vim.fn.fnamemodify(st.path, ":t"), vim.log.levels.INFO)

  output.decorate_separators(bufnr)
end

-- ── Cell queries ──────────────────────────────────────────────────────────────

--- Return cell info at cursor in `bufnr`.
---@return table|nil
function M.current_cell(bufnr)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  return notebook.cell_at_row(bufnr, row)
end

--- Return all parsed cells for `bufnr`.
function M.all_cells(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return notebook.lines_to_cells(lines)
end

--- Generate the runtime cell_id used to route kernel output.
--- Encodes cell_index (stable across row insertions from output blocks).
function M.cell_exec_id(bufnr, cell_index)
  return string.format("buf%d_idx%d", bufnr, cell_index)
end

-- ── State accessors ───────────────────────────────────────────────────────────

function M.is_loaded(bufnr)
  return _state[bufnr] ~= nil
end

function M.get_path(bufnr)
  local st = _state[bufnr]
  return st and st.path
end

function M.cleanup(bufnr)
  kernel.stop(bufnr)
  _state[bufnr] = nil
end

--- Update structured outputs for one cell in cells_meta (called by kernel on each output event).
---@param bufnr integer
---@param cell_index integer  1-based
---@param outputs table[]
function M.update_cell_outputs(bufnr, cell_index, outputs)
  local st = _state[bufnr]
  if not st then return end
  local cm = st.cells_meta[cell_index]
  if cm then
    cm.outputs = vim.deepcopy(outputs)
  end
end

--- Clear stored cell outputs (both cells_meta and output blocks in the buffer).
function M.clear_stored_outputs(bufnr)
  local st = _state[bufnr]
  if not st then return end
  for _, cm in ipairs(st.cells_meta or {}) do
    cm.outputs         = {}
    cm.execution_count = nil
  end
  output.clear_all_output_blocks(bufnr)
end

--- Initialize buffer state for a newly scaffolded notebook.
function M.init_state(bufnr, path, nb)
  local cells_meta = {}
  for _, c in ipairs(nb.cells or {}) do
    table.insert(cells_meta, {
      id              = c.id,
      metadata        = c.metadata or {},
      outputs         = c.outputs or {},
      execution_count = c.execution_count,
    })
  end
  _state[bufnr] = {
    path           = path,
    nb_meta        = nb.metadata,
    nbformat       = nb.nbformat,
    nbformat_minor = nb.nbformat_minor,
    cells_meta     = cells_meta,
  }
end

-- ── Autocmds ─────────────────────────────────────────────────────────────────

function M._attach_autocmds(bufnr)
  local grp = vim.api.nvim_create_augroup("jup_buf_" .. bufnr, { clear = true })

  -- BufWipeout (not BufDelete): BufDelete fires when buflisted is set to false,
  -- which scope.nvim does on every tab switch, destroying state we need to keep.
  -- BufWipeout only fires when the buffer is truly removed from memory.
  vim.api.nvim_create_autocmd("BufWipeout", {
    group  = grp,
    buffer = bufnr,
    callback = function()
      M.cleanup(bufnr)
      vim.api.nvim_del_augroup_by_id(grp)
    end,
  })

  -- Re-decorate after text changes (debounced)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group    = grp,
    buffer   = bufnr,
    callback = function()
      local st = _state[bufnr]
      if not st then return end
      if st._decorate_timer then st._decorate_timer:stop() end
      st._decorate_timer = vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          output.decorate_separators(bufnr)
        end
      end, 300)
    end,
  })
end

-- ── Internal helpers ──────────────────────────────────────────────────────────

function M._read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

function M._set_filetype(bufnr, metadata)
  local lang   = (metadata.kernelspec or {}).language or "python"
  local ft_map = { python = "python", julia = "julia", r = "r", ruby = "ruby" }
  vim.bo[bufnr].filetype = ft_map[lang] or "python"
end

--- Insert output blocks for all cells that have saved outputs.
--- Inserted in reverse order so earlier row numbers stay valid across insertions.
function M._restore_outputs(bufnr, cells)
  local lines  = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local parsed = notebook.lines_to_cells(lines)

  for i = #parsed, 1, -1 do
    local pc = parsed[i]
    local c  = cells[i]
    if c and c.cell_type == "code" and c.outputs and #c.outputs > 0 then
      local text_lines = output.format_output_lines(c.outputs)
      if #text_lines > 0 then
        local block = { notebook.make_output_separator() }
        for _, l in ipairs(text_lines) do table.insert(block, l) end
        local insert_at = pc.source_end_row + 1
        vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, block)
      end
    end
  end
end

function M._pretty_json(json_str)
  local tmp = os.tmpname()
  local f = io.open(tmp, "w")
  if not f then return json_str end
  f:write(json_str)
  f:close()

  local out = vim.fn.system("python3 -m json.tool --indent 1 " .. vim.fn.shellescape(tmp))
  os.remove(tmp)

  if vim.v.shell_error == 0 and out ~= "" then return out end
  return json_str
end

function M._new_cell_id(index)
  return string.format("%08x", index + os.time() * 1000)
end

--- Scaffold a blank notebook into bufnr (called when the file doesn't exist yet).
function M._scaffold(bufnr, path)
  local nb = {
    metadata = {
      kernelspec    = { display_name = "Python 3", language = "python", name = "python3" },
      language_info = { name = "python" },
    },
    nbformat       = 4,
    nbformat_minor = 5,
    cells = {
      { id = "00000001", cell_type = "code", source = "", metadata = {}, outputs = {}, execution_count = vim.NIL },
    },
  }

  M.init_state(bufnr, path, nb)

  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buftype  = "acwrite"

  local lines = notebook.notebook_to_lines(nb)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].filetype = "python"

  output.setup_highlights()
  output.decorate_separators(bufnr)
  require("jup")._apply_keymaps(bufnr)
  M._attach_autocmds(bufnr)
end

return M
