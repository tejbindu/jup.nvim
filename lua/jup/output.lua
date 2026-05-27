-- Renders cell borders and output as real buffer lines.
-- Output blocks are inserted as "# %% [out]" + text after each cell's source.
-- Separator extmarks (top/bottom borders, running indicator) use the jup_sep namespace.

local M = {}
local config = require("jup.config")

local _ns_sep = nil

function M.ns_sep()
  if not _ns_sep then _ns_sep = vim.api.nvim_create_namespace("jup_sep") end
  return _ns_sep
end

-- ─── Highlights ───────────────────────────────────────────────────────────────

function M.setup_highlights()
  local hls = {
    JupSeparator   = { link = "Comment",        default = true },
    JupSeparatorMd = { link = "Title",           default = true },
    JupRunning     = { link = "DiagnosticWarn",  default = true },
    JupExecCount   = { link = "Number",          default = true },
    JupOutputSep   = { link = "Comment",         default = true },
  }
  for name, opts in pairs(hls) do
    vim.api.nvim_set_hl(0, name, opts)
  end
end

-- ─── Border helpers ───────────────────────────────────────────────────────────

local function win_content_width(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then return 80 end
  local w = vim.api.nvim_win_get_width(win)
  return math.max(40, w - 3)
end

local function top_border(cell_type, width, running, exec_count)
  local hl_label  = cell_type == "markdown" and " markdown " or " code "
  local count_str = exec_count and string.format("[%d]", exec_count) or ""
  local run_str   = running and " ▶ " or ""
  local label     = run_str .. hl_label .. count_str
  local dashes    = width - #label - 3
  return "╭─" .. label .. string.rep("─", math.max(0, dashes)) .. "╮"
end

local function bot_border(width)
  return "╰" .. string.rep("─", math.max(0, width - 2)) .. "╯"
end

local function out_border(width)
  local label  = "─ output "
  local dashes = width - #label - 2  -- ├ and ┤
  return "├" .. label .. string.rep("─", math.max(0, dashes)) .. "┤"
end

-- ─── Separator / cell decoration ─────────────────────────────────────────────
--
-- _sep_state is keyed [bufnr][cell_index] so it remains correct even after
-- output block insertions shift row numbers.

local _sep_state = {}

local function render_sep(bufnr, cell_index, sep_row, cell_type, running, exec_count)
  local width  = win_content_width(bufnr)
  local hl     = cell_type == "markdown" and "JupSeparatorMd" or "JupSeparator"
  local run_hl = running and "JupRunning" or hl
  local top    = top_border(cell_type, width, running, exec_count)

  local state = (_sep_state[bufnr] or {})[cell_index]
  local id    = state and state.mark_id or nil

  -- When updating an existing mark, query its current tracked position so the
  -- render lands at the right row even if output insertions shifted it.
  local actual_row = sep_row
  if id then
    local info = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_sep(), id, {})
    if info and info[1] then actual_row = info[1] end
  end

  local opts = {
    virt_text     = { { top, run_hl } },
    virt_text_pos = "overlay",
    priority      = 200,
  }
  if id then opts.id = id end

  local new_id = vim.api.nvim_buf_set_extmark(bufnr, M.ns_sep(), actual_row, 0, opts)
  if not _sep_state[bufnr] then _sep_state[bufnr] = {} end
  _sep_state[bufnr][cell_index] = {
    cell_type  = cell_type,
    running    = running,
    exec_count = exec_count,
    mark_id    = new_id,
    sep_row    = actual_row,
  }
end

local function render_out_sep(bufnr, cell_index, out_sep_row)
  local width = win_content_width(bufnr)
  local ns    = M.ns_sep()
  local state = (_sep_state[bufnr] or {})[cell_index]
  local id    = state and state.out_mark_id or nil
  local opts  = {
    virt_text     = { { out_border(width), "JupOutputSep" } },
    virt_text_pos = "overlay",
    priority      = 150,
  }
  if id then opts.id = id end
  local new_id = vim.api.nvim_buf_set_extmark(bufnr, ns, out_sep_row, 0, opts)
  if not _sep_state[bufnr] then _sep_state[bufnr] = {} end
  if not _sep_state[bufnr][cell_index] then _sep_state[bufnr][cell_index] = {} end
  _sep_state[bufnr][cell_index].out_mark_id = new_id
end

--- Redraw all cell borders for `bufnr`.
--- Preserves running/exec_count state from the previous decoration.
function M.decorate_separators(bufnr)
  local notebook  = require("jup.notebook")
  local prev_state = _sep_state[bufnr] or {}

  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_sep(), 0, -1)
  _sep_state[bufnr] = {}

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cells = notebook.lines_to_cells(lines)
  if #cells == 0 then return end

  local width = win_content_width(bufnr)
  local bot   = bot_border(width)
  local ns    = M.ns_sep()

  for i, cell in ipairs(cells) do
    local prev = prev_state[i] or {}
    render_sep(bufnr, i, cell.sep_row, cell.cell_type, prev.running or false, prev.exec_count)

    if cell.output_sep_row then
      render_out_sep(bufnr, i, cell.output_sep_row)
    end

    local hl       = cell.cell_type == "markdown" and "JupSeparatorMd" or "JupSeparator"
    local next_cell = cells[i + 1]
    if next_cell then
      vim.api.nvim_buf_set_extmark(bufnr, ns, next_cell.sep_row, 0, {
        virt_lines       = { { { bot, hl } } },
        virt_lines_above = true,
        priority         = 100,
      })
    else
      vim.api.nvim_buf_set_extmark(bufnr, ns, cell.end_row, 0, {
        virt_lines       = { { { bot, hl } } },
        virt_lines_above = false,
        priority         = 100,
      })
    end
  end
end

--- Show or hide the running indicator on a cell's top border.
---@param bufnr integer
---@param cell_index integer  1-based
---@param running boolean
function M.set_running(bufnr, cell_index, running)
  local state = (_sep_state[bufnr] or {})[cell_index]
  if not state then return end
  render_sep(bufnr, cell_index, state.sep_row, state.cell_type, running, state.exec_count)
end

---@param bufnr integer
---@param cell_index integer  1-based
---@param count integer
function M.set_exec_count(bufnr, cell_index, count)
  local state = (_sep_state[bufnr] or {})[cell_index]
  if not state then return end
  render_sep(bufnr, cell_index, state.sep_row, state.cell_type, state.running, count)
end

-- ─── Output block helpers ────────────────────────────────────────────────────

--- Convert output objects to a flat list of plain-text lines for buffer insertion.
--- ANSI codes are always stripped (they appear as garbage in normal buffers).
---@param outputs table[]
---@return string[]
function M.format_output_lines(outputs)
  local cfg       = config.get()
  local max       = cfg.display.max_output_lines
  local lines     = {}
  local truncated = false

  local function add(text)
    local clean = text:gsub("\27%[[%d;]*m", "")
    for _, l in ipairs(vim.split(clean, "\n", { plain = true })) do
      if max > 0 and #lines >= max then
        if not truncated then
          table.insert(lines, " … output truncated")
          truncated = true
        end
        return
      end
      table.insert(lines, l)
    end
  end

  for _, out in ipairs(outputs or {}) do
    local ot = out.output_type
    if ot == "stream" then
      add(out.text or "")
    elseif ot == "execute_result" or ot == "display_data" then
      local data = out.data or {}
      local text = data["text/plain"]
      if text then
        add(type(text) == "table" and table.concat(text, "") or text)
      elseif data["image/png"] or data["image/jpeg"] then
        table.insert(lines, "[image output]")
      end
    elseif ot == "error" then
      add(string.format("%s: %s", out.ename or "Error", out.evalue or ""))
      for _, tb in ipairs(out.traceback or {}) do
        add(tb)
      end
    end
  end

  -- Trim trailing blank lines
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end

  return lines
end

--- Insert or replace the output block for cell `cell_index`.
--- If `text_lines` is empty the existing block (if any) is removed instead.
---@param bufnr integer
---@param cell_index integer  1-based
---@param text_lines string[]
function M.set_output_block(bufnr, cell_index, text_lines)
  local notebook = require("jup.notebook")
  local lines    = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cells    = notebook.lines_to_cells(lines)
  local cell     = cells[cell_index]
  if not cell then return end

  if #text_lines == 0 then
    M.clear_output_block(bufnr, cell_index)
    return
  end

  local block = { notebook.make_output_separator() }
  for _, l in ipairs(text_lines) do table.insert(block, l) end

  local out_sep_row
  if cell.output_sep_row then
    -- Replace existing block; nvim_buf_set_lines destroys the extmark so we re-place it
    vim.api.nvim_buf_set_lines(bufnr, cell.output_sep_row, cell.output_end_row + 1, false, block)
    out_sep_row = cell.output_sep_row
  else
    -- Insert after last source line
    local insert_at = cell.source_end_row + 1
    vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, block)
    out_sep_row = insert_at
  end
  render_out_sep(bufnr, cell_index, out_sep_row)
end

--- Remove the output block for cell `cell_index` (no-op if none exists).
---@param bufnr integer
---@param cell_index integer  1-based
function M.clear_output_block(bufnr, cell_index)
  local notebook = require("jup.notebook")
  local lines    = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cells    = notebook.lines_to_cells(lines)
  local cell     = cells[cell_index]
  if not cell or not cell.output_sep_row then return end
  -- Delete extmark before removing lines to prevent Neovim from pushing it to the wrong row
  local state = (_sep_state[bufnr] or {})[cell_index]
  if state and state.out_mark_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns_sep(), state.out_mark_id)
    state.out_mark_id = nil
  end
  vim.api.nvim_buf_set_lines(bufnr, cell.output_sep_row, cell.output_end_row + 1, false, {})
end

--- Remove all output blocks from `bufnr` in one pass (reverse order so row
--- numbers stay valid across deletions).
---@param bufnr integer
function M.clear_all_output_blocks(bufnr)
  local notebook = require("jup.notebook")
  local lines    = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cells    = notebook.lines_to_cells(lines)
  for i = #cells, 1, -1 do
    local c = cells[i]
    if c.output_sep_row then
      vim.api.nvim_buf_set_lines(bufnr, c.output_sep_row, c.output_end_row + 1, false, {})
    end
  end
  M.decorate_separators(bufnr)
end

return M
