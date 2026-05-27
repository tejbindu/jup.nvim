-- jup.nvim public API
-- All user-facing functions live here.

local M = {}

local config   = require("jup.config")
local notebook = require("jup.notebook")
local buf      = require("jup.buffer")
local kernel   = require("jup.kernel")
local output   = require("jup.output")

-- ── Internal helpers ──────────────────────────────────────────────────────────

-- Return the current buffer if it is a loaded notebook, otherwise search the
-- current tab's windows for one. This lets kernel/save commands work even when
-- the cursor is sitting in a sidebar (neotree, etc.) with the notebook visible
-- in another window.
local function _notebook_buf()
  local cur = vim.api.nvim_get_current_buf()
  if buf.is_loaded(cur) then return cur end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    if buf.is_loaded(b) then return b end
  end
  return cur  -- caller's "not a notebook" error handles this
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param opts table|nil  see config.lua for available keys
function M.setup(opts)
  if vim.g.jup_nvim_setup_done then return end
  vim.g.jup_nvim_setup_done = true
  config.setup(opts or {})
  output.setup_highlights()
  require("jup.commands").setup()
  M._register_autocmds()
end

-- ── Kernel management ─────────────────────────────────────────────────────────

--- Connect to or start a kernel for the current notebook buffer.
---@param opts table|nil  {kernel_name?, connection_file?}
function M.connect(opts)
  local bufnr = _notebook_buf()
  if not buf.is_loaded(bufnr) then
    vim.notify("[jup.nvim] current buffer is not a notebook", vim.log.levels.WARN)
    return
  end

  opts = opts or {}
  kernel.connect(bufnr, opts, function(err, data)
    if err then
      vim.notify("[jup.nvim] connect failed: " .. tostring(err), vim.log.levels.ERROR)
    else
      local name = (data or {}).kernel_name or "kernel"
      vim.notify("[jup.nvim] connected to " .. name, vim.log.levels.INFO)
    end
  end)
end

--- Stop the kernel bridge for the current buffer.
function M.disconnect()
  local bufnr = _notebook_buf()
  kernel.stop(bufnr)
  vim.notify("[jup.nvim] kernel disconnected", vim.log.levels.INFO)
end

--- Restart the kernel.
function M.restart()
  local bufnr = _notebook_buf()
  kernel.restart(bufnr, function(err, _)
    if err then
      vim.notify("[jup.nvim] restart failed: " .. tostring(err), vim.log.levels.ERROR)
    else
      vim.notify("[jup.nvim] kernel restarted", vim.log.levels.INFO)
    end
  end)
end

--- Interrupt the running kernel.
function M.interrupt()
  local bufnr = _notebook_buf()
  kernel.interrupt(bufnr, function(err, _)
    if err then
      vim.notify("[jup.nvim] interrupt failed: " .. tostring(err), vim.log.levels.ERROR)
    else
      vim.notify("[jup.nvim] kernel interrupted", vim.log.levels.INFO)
    end
  end)
end

--- Show kernel info in a notification.
function M.kernel_info()
  local bufnr = _notebook_buf()
  kernel.kernel_info(bufnr, function(err, data)
    if err then
      vim.notify("[jup.nvim] " .. tostring(err), vim.log.levels.ERROR)
    else
      local d = data or {}
      vim.notify(string.format("[jup.nvim] %s %s (%s)",
        d.implementation or "?", d.version or "?", d.language or "?"),
        vim.log.levels.INFO)
    end
  end)
end

--- Return true if a kernel bridge is connected for the current buffer.
--- Useful for statusline integrations.
function M.is_connected()
  return kernel.is_running(_notebook_buf())
end

-- ── Cell execution ─────────────────────────────────────────────────────────────

--- Execute the cell under the cursor.
---@param callback function|nil  called with (err) on completion
function M.run_cell(callback)
  local bufnr = vim.api.nvim_get_current_buf()
  local cell  = buf.current_cell(bufnr)
  if not cell then
    vim.notify("[jup.nvim] cursor is not inside a cell", vim.log.levels.WARN)
    return
  end

  M._ensure_connected(bufnr, function(err)
    if err then return end
    M._execute_cell(bufnr, cell, callback)
  end)
end

--- Execute all cells sequentially.
function M.run_all()
  local bufnr = _notebook_buf()
  local cells = buf.all_cells(bufnr)
  if #cells == 0 then return end

  -- Collect indices of all cells; re-scan before each execution so row positions
  -- are always current (output block insertions shift subsequent rows).
  local indices = {}
  for _, c in ipairs(cells) do table.insert(indices, c.cell_index) end

  M._ensure_connected(bufnr, function(err)
    if err then return end
    M._run_sequence(bufnr, indices, 1, nil)
  end)
end

--- Execute all cells above the cursor (exclusive).
function M.run_above()
  local bufnr    = vim.api.nvim_get_current_buf()
  local cur_cell = buf.current_cell(bufnr)
  if not cur_cell then return end

  local cells   = buf.all_cells(bufnr)
  local indices = {}
  for _, c in ipairs(cells) do
    if c.cell_index < cur_cell.cell_index then
      table.insert(indices, c.cell_index)
    end
  end

  M._ensure_connected(bufnr, function(err)
    if err then return end
    M._run_sequence(bufnr, indices, 1, nil)
  end)
end

--- Execute current cell and all cells below it.
function M.run_below()
  local bufnr    = vim.api.nvim_get_current_buf()
  local cur_cell = buf.current_cell(bufnr)
  if not cur_cell then return end

  local cells   = buf.all_cells(bufnr)
  local indices = {}
  for _, c in ipairs(cells) do
    if c.cell_index >= cur_cell.cell_index then
      table.insert(indices, c.cell_index)
    end
  end

  M._ensure_connected(bufnr, function(err)
    if err then return end
    M._run_sequence(bufnr, indices, 1, nil)
  end)
end

-- ── Output management ─────────────────────────────────────────────────────────

--- Clear all outputs in the current buffer.
function M.clear_outputs()
  local bufnr = _notebook_buf()
  kernel.clear_outputs(bufnr)
  buf.clear_stored_outputs(bufnr)
end

--- Yank the output of the cell under the cursor into the clipboard.
--- Reads directly from the output block lines in the buffer.
function M.yank_cell_output()
  local bufnr = vim.api.nvim_get_current_buf()
  local cell  = buf.current_cell(bufnr)
  if not cell then
    vim.notify("[jup.nvim] cursor is not inside a cell", vim.log.levels.WARN)
    return
  end
  if not cell.output_sep_row then
    vim.notify("[jup.nvim] no output for this cell", vim.log.levels.INFO)
    return
  end
  -- output block: rows (output_sep_row+1) .. output_end_row (skip the # %% [out] line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, cell.output_sep_row + 1, cell.output_end_row + 1, false)
  local text  = table.concat(lines, "\n")
  vim.fn.setreg("+", text)
  vim.fn.setreg('"', text)
  vim.notify("[jup.nvim] output copied to clipboard", vim.log.levels.INFO)
end

--- Clear output for the cell under the cursor.
function M.clear_cell_output()
  local bufnr = vim.api.nvim_get_current_buf()
  local cell  = buf.current_cell(bufnr)
  if not cell then return end
  kernel.clear_cell_output(bufnr, cell.cell_index)
end

-- ── Cell navigation ───────────────────────────────────────────────────────────

--- Move cursor to the first line of the next cell.
function M.goto_next_cell()
  local bufnr  = vim.api.nvim_get_current_buf()
  local row    = vim.api.nvim_win_get_cursor(0)[1] - 1
  local lines  = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local found  = false
  for i = row + 2, #lines do  -- +2: skip current row and use 1-indexed
    if notebook.parse_separator(lines[i]) then
      vim.api.nvim_win_set_cursor(0, { i + 1, 0 })  -- move to line after separator
      found = true
      break
    end
  end
  if not found then
    vim.notify("[jup.nvim] no next cell", vim.log.levels.INFO)
  end
end

--- Move cursor to the first line of the previous cell.
function M.goto_prev_cell()
  local bufnr  = vim.api.nvim_get_current_buf()
  local row    = vim.api.nvim_win_get_cursor(0)[1] - 1
  local lines  = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Find the separator of the current cell first
  local cur_sep = nil
  for i = row + 1, 1, -1 do
    if notebook.parse_separator(lines[i]) then
      cur_sep = i
      break
    end
  end

  -- Find the separator before that
  if cur_sep and cur_sep > 1 then
    for i = cur_sep - 1, 1, -1 do
      if notebook.parse_separator(lines[i]) then
        vim.api.nvim_win_set_cursor(0, { i + 1, 0 })
        return
      end
    end
  end
  vim.notify("[jup.nvim] no previous cell", vim.log.levels.INFO)
end

-- ── Cell editing ──────────────────────────────────────────────────────────────

--- Insert a new cell below the current cell.
---@param cell_type string  "code" | "markdown" | "raw"
function M.new_cell(cell_type)
  cell_type = cell_type or "code"
  local bufnr = vim.api.nvim_get_current_buf()
  local cell  = buf.current_cell(bufnr)

  local insert_row
  if cell then
    insert_row = cell.end_row + 1  -- after last line of current cell
  else
    insert_row = vim.api.nvim_buf_line_count(bufnr)
  end

  local sep = notebook.make_separator(cell_type)
  vim.api.nvim_buf_set_lines(bufnr, insert_row, insert_row, false, { "", sep, "" })
  -- Position cursor on the blank line after the separator
  vim.api.nvim_win_set_cursor(0, { insert_row + 3, 0 })

  output.decorate_separators(bufnr)
end

--- Delete the cell under the cursor (separator + source).
function M.delete_cell()
  local bufnr = vim.api.nvim_get_current_buf()
  local cell  = buf.current_cell(bufnr)
  if not cell then
    vim.notify("[jup.nvim] cursor is not inside a cell", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_buf_set_lines(bufnr, cell.sep_row, cell.end_row + 1, false, {})
  output.decorate_separators(bufnr)
end

-- ── Save ─────────────────────────────────────────────────────────────────────

function M.save()
  buf.save(_notebook_buf())
end

-- ── Status ────────────────────────────────────────────────────────────────────

function M.show_status()
  local bufnr = _notebook_buf()
  local path  = buf.get_path(bufnr)
  if not path then
    vim.notify("[jup.nvim] not a notebook buffer", vim.log.levels.WARN)
    return
  end
  local running = kernel.is_running(bufnr)
  local status  = running and "connected" or "disconnected"
  vim.notify(string.format("[jup.nvim] %s | kernel: %s",
    vim.fn.fnamemodify(path, ":t"), status), vim.log.levels.INFO)
end

-- ── Autocmds ─────────────────────────────────────────────────────────────────

function M._register_autocmds()
  local grp = vim.api.nvim_create_augroup("jup_global", { clear = true })

  -- Intercept opening .ipynb files (fires for both existing and new files)
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group   = grp,
    pattern = "*.ipynb",
    callback = function(ev)
      buf.load(ev.buf, vim.fn.fnamemodify(ev.match, ":p"))
    end,
  })

  -- Intercept saving .ipynb files
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group   = grp,
    pattern = "*.ipynb",
    callback = function(ev)
      buf.save(ev.buf)
    end,
  })

  -- Re-initialize if state was lost while the buffer was hidden (e.g., a plugin
  -- called :bdelete which fires BufDelete → cleanup, but the buffer still exists).
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group   = grp,
    pattern = "*.ipynb",
    callback = function(ev)
      if not buf.is_loaded(ev.buf) and not vim.bo[ev.buf].modified then
        local path = vim.api.nvim_buf_get_name(ev.buf)
        if path ~= "" then
          buf.load(ev.buf, path)
        end
      end
    end,
  })
end


-- ── Keymap application ───────────────────────────────────────────────────────

-- Maps config key → {api function, description}
local _keymap_actions = {
  run_cell      = { function() M.run_cell()                end, "Jup: run cell" },
  run_all       = { function() M.run_all()                 end, "Jup: run all cells" },
  run_above     = { function() M.run_above()               end, "Jup: run cells above" },
  run_below     = { function() M.run_below()               end, "Jup: run cell and below" },
  connect       = { function() M.connect()                 end, "Jup: connect kernel" },
  disconnect    = { function() M.disconnect()              end, "Jup: disconnect kernel" },
  interrupt     = { function() M.interrupt()               end, "Jup: interrupt kernel" },
  restart       = { function() M.restart()                 end, "Jup: restart kernel" },
  kernel_info   = { function() M.kernel_info()             end, "Jup: kernel info" },
  show_status   = { function() M.show_status()             end, "Jup: status" },
  clear_outputs = { function() M.clear_outputs()           end, "Jup: clear all outputs" },
  clear_cell    = { function() M.clear_cell_output()       end, "Jup: clear cell output" },
  yank_output   = { function() M.yank_cell_output()        end, "Jup: yank cell output to clipboard" },
  new_cell_code = { function() M.new_cell("code")          end, "Jup: new code cell" },
  new_cell_md   = { function() M.new_cell("markdown")      end, "Jup: new markdown cell" },
  delete_cell   = { function() M.delete_cell()             end, "Jup: delete cell" },
  next_cell     = { function() M.goto_next_cell()          end, "Jup: next cell" },
  prev_cell     = { function() M.goto_prev_cell()          end, "Jup: prev cell" },
  save          = { function() M.save()                    end, "Jup: save notebook" },
}

--- Apply buffer-local keymaps for `bufnr` according to config.keymaps.
function M._apply_keymaps(bufnr)
  local cfg = config.get()
  if cfg.keymaps == false then return end
  local keymaps = cfg.keymaps or {}

  for name, action in pairs(_keymap_actions) do
    local lhs = keymaps[name]
    if lhs and lhs ~= false then
      vim.keymap.set("n", lhs, action[1], {
        buffer  = bufnr,
        silent  = true,
        desc    = action[2],
      })
    end
  end
end

function M._ensure_connected(bufnr, callback)
  if kernel.is_running(bufnr) then
    callback(nil)
    return
  end
  local cfg = config.get()
  vim.notify("[jup.nvim] starting kernel '" .. cfg.kernel.default .. "'…", vim.log.levels.INFO)
  kernel.connect(bufnr, {}, function(err, _)
    if err then
      vim.notify("[jup.nvim] " .. tostring(err), vim.log.levels.ERROR)
      callback(err)
    else
      callback(nil)
    end
  end)
end

function M._execute_cell(bufnr, cell, callback)
  if cell.cell_type ~= "code" then
    if callback then callback(nil) end
    return
  end

  local cell_id = buf.cell_exec_id(bufnr, cell.cell_index)
  kernel.execute(bufnr, cell_id, cell.source, cell.cell_index, function(err)
    if callback then callback(err) end
  end)
end

--- Run cells identified by `indices[i]` then proceed to the next.
--- Re-scans the buffer before each cell so row positions are always current
--- (output block insertions from prior cells shift subsequent rows).
function M._run_sequence(bufnr, indices, i, on_all_done)
  if i > #indices then
    if on_all_done then on_all_done() end
    return
  end
  local cell_index = indices[i]
  local cells      = buf.all_cells(bufnr)
  local cell       = cells[cell_index]
  if not cell or cell.cell_type ~= "code" then
    M._run_sequence(bufnr, indices, i + 1, on_all_done)
    return
  end
  M._execute_cell(bufnr, cell, function(_)
    M._run_sequence(bufnr, indices, i + 1, on_all_done)
  end)
end

return M
