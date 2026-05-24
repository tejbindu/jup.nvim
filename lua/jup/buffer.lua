-- Manages the notebook buffer lifecycle:
--   BufReadCmd  → parse .ipynb → write cell format → set up extmarks
--   BufWriteCmd → parse buffer → serialize .ipynb → write file
--   BufDelete   → clean up kernel and extmarks

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
  -- Guard: only load once per buffer
  if _state[bufnr] then return end

  path = vim.fn.fnamemodify(path, ":p")

  local raw = M._read_file(path)

  -- File doesn't exist yet → scaffold a blank notebook
  if not raw then
    M._scaffold(bufnr, path)
    return
  end

  local ok, nb = pcall(notebook.parse_ipynb, raw)
  if not ok then
    vim.notify("[jup.nvim] " .. tostring(nb), vim.log.levels.ERROR)
    return
  end

  -- Store per-cell metadata (outputs, execution_count, cell id, metadata)
  -- so we can round-trip them correctly on save.
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
    path       = path,
    nb_meta    = nb.metadata,
    nbformat   = nb.nbformat,
    nbformat_minor = nb.nbformat_minor,
    cells_meta = cells_meta,
  }

  -- Render cells into buffer
  local lines = notebook.notebook_to_lines(nb)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false

  -- Apply syntax / filetype
  M._set_filetype(bufnr, nb.metadata)

  -- Decorate separator lines
  output.setup_highlights()
  output.decorate_separators(bufnr)

  -- Restore saved outputs as virtual lines
  M._restore_outputs(bufnr, nb.cells)

  -- Apply buffer-local keymaps
  require("jup")._apply_keymaps(bufnr)

  -- Attach autocmds for this buffer
  M._attach_autocmds(bufnr)
end

--- Save buffer contents back to the .ipynb file.
---@param bufnr integer
function M.save(bufnr)
  local st = _state[bufnr]
  if not st then return end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local parsed = notebook.lines_to_cells(lines)

  -- Build full cell list, merging saved metadata with current source
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

  -- Pretty-print: use python-json-tool if available, else raw
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

  -- Refresh separator decoration (user may have added new cells)
  output.decorate_separators(bufnr)
end

-- ── Cell queries ──────────────────────────────────────────────────────────────

--- Return cell info at cursor in `bufnr`.
---@return table|nil  {cell_type, sep_row, end_row, source, cell_index}
function M.current_cell(bufnr)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed
  local cell = notebook.cell_at_row(bufnr, row)
  return cell
end

--- Return all parsed cells for `bufnr`.
function M.all_cells(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return notebook.lines_to_cells(lines)
end

--- Generate a stable cell_id string for a given cell during execution.
--- This is the runtime ID used to route kernel output — it resets on reload.
function M.cell_exec_id(bufnr, sep_row)
  return string.format("buf%d_row%d", bufnr, sep_row)
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
  output.clear_all_outputs(bufnr)
  _state[bufnr] = nil
end

--- Clear stored cell outputs (does not touch extmarks).
function M.clear_stored_outputs(bufnr)
  local st = _state[bufnr]
  if not st then return end
  for _, cm in ipairs(st.cells_meta or {}) do
    cm.outputs         = {}
    cm.execution_count = nil
  end
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

  vim.api.nvim_create_autocmd("BufDelete", {
    group  = grp,
    buffer = bufnr,
    callback = function()
      M.cleanup(bufnr)
      vim.api.nvim_del_augroup_by_id(grp)
    end,
  })

  -- Re-decorate after the buffer is modified (new cells may have been added)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group    = grp,
    buffer   = bufnr,
    callback = function()
      if M._decorate_timer then M._decorate_timer:stop() end
      M._decorate_timer = vim.defer_fn(function()
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
  local lang = (metadata.kernelspec or {}).language or "python"
  -- Map kernel language to Neovim filetype
  local ft_map = { python = "python", julia = "julia", r = "r", ruby = "ruby" }
  local ft = ft_map[lang] or "python"
  vim.bo[bufnr].filetype = ft
end

function M._restore_outputs(bufnr, cells)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local parsed = notebook.lines_to_cells(lines)
  for i, pc in ipairs(parsed) do
    local c = cells[i]
    if c and c.cell_type == "code" and c.outputs and #c.outputs > 0 then
      -- Compute anchor row (last line of cell content, not separator)
      local anchor = pc.end_row
      output.set_cell_output(bufnr, anchor, c.outputs, nil)
    end
  end
end

function M._pretty_json(json_str)
  -- Attempt to pretty-print via Python; fall back to raw on failure
  local tmp = os.tmpname()
  local f = io.open(tmp, "w")
  if not f then return json_str end
  f:write(json_str)
  f:close()

  local out = vim.fn.system("python3 -m json.tool --indent 1 " .. vim.fn.shellescape(tmp))
  os.remove(tmp)

  if vim.v.shell_error == 0 and out ~= "" then
    return out
  end
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
