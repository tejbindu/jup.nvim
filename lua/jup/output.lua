-- Renders cell borders, outputs, and running indicators using extmarks.

local M = {}
local config = require("jup.config")

local _ns_output = nil
local _ns_sep    = nil

function M.ns_output()
  if not _ns_output then _ns_output = vim.api.nvim_create_namespace("jup_output") end
  return _ns_output
end

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
    JupStdout      = { link = "String",          default = true },
    JupStderr      = { link = "DiagnosticError", default = true },
    JupResult      = { link = "Normal",          default = true },
    JupError       = { link = "DiagnosticError", default = true },
    JupExecCount   = { link = "Number",          default = true },
    JupOutputBg    = { link = "CursorLine",      default = true },
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
  return math.max(40, w - 3)  -- subtract sign/number column gutter
end

--- Build the top border string for a cell.
local function top_border(cell_type, width, running, exec_count)
  local hl_label = cell_type == "markdown" and " markdown " or " code "
  local count_str = exec_count and string.format("[%d]", exec_count) or ""
  local run_str   = running and " ▶ " or ""
  local label     = run_str .. hl_label .. count_str
  local dashes    = width - #label - 3   -- 3 = ╭─ … ╮
  return "╭─" .. label .. string.rep("─", math.max(0, dashes)) .. "╮"
end

--- Build the bottom border string.
local function bot_border(width)
  return "╰" .. string.rep("─", math.max(0, width - 2)) .. "╯"
end

-- ─── Separator / cell decoration ─────────────────────────────────────────────

local _sep_state = {}   -- [bufnr][sep_row] = {cell_type, running, exec_count, mark_id}

local function render_sep(bufnr, sep_row, cell_type, running, exec_count)
  local width  = win_content_width(bufnr)
  local hl     = cell_type == "markdown" and "JupSeparatorMd" or "JupSeparator"
  local run_hl = running and "JupRunning" or hl
  local top    = top_border(cell_type, width, running, exec_count)

  local buf_state = _sep_state[bufnr]
  local state     = buf_state and buf_state[sep_row]
  local id        = state and state.mark_id or nil

  local opts = {
    virt_text     = { { top, run_hl } },
    virt_text_pos = "overlay",
    priority      = 200,
  }
  if id then opts.id = id end

  local new_id = vim.api.nvim_buf_set_extmark(bufnr, M.ns_sep(), sep_row, 0, opts)
  if not _sep_state[bufnr] then _sep_state[bufnr] = {} end
  _sep_state[bufnr][sep_row] = { cell_type = cell_type, running = running, exec_count = exec_count, mark_id = new_id }
end

--- Redraw all cell borders (top + bottom) for `bufnr`.
--- Called on load and after TextChanged.
function M.decorate_separators(bufnr)
  local notebook = require("jup.notebook")
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_sep(), 0, -1)
  _sep_state[bufnr] = {}

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cells = notebook.lines_to_cells(lines)
  if #cells == 0 then return end

  local width = win_content_width(bufnr)
  local bot   = bot_border(width)
  local ns    = M.ns_sep()

  for i, cell in ipairs(cells) do
    -- Top border: overlay on the separator line (hides # %%)
    render_sep(bufnr, cell.sep_row, cell.cell_type, false, nil)

    -- Bottom border: virtual line above the next separator (or below last cell)
    local hl = cell.cell_type == "markdown" and "JupSeparatorMd" or "JupSeparator"
    local next_cell = cells[i + 1]
    if next_cell then
      -- Appears visually between the two cells (above next top border)
      vim.api.nvim_buf_set_extmark(bufnr, ns, next_cell.sep_row, 0, {
        virt_lines       = { { { bot, hl } } },
        virt_lines_above = true,
        priority         = 100,
      })
    else
      -- Last cell: bottom border below its last content line
      vim.api.nvim_buf_set_extmark(bufnr, ns, cell.end_row, 0, {
        virt_lines       = { { { bot, hl } } },
        virt_lines_above = false,
        priority         = 100,
      })
    end
  end
end

-- ─── Running / exec-count indicators ─────────────────────────────────────────

--- Show or hide the running indicator on a separator line's top border.
function M.set_running(bufnr, sep_row, running)
  local state = (_sep_state[bufnr] or {})[sep_row]
  if not state then
    local lines = vim.api.nvim_buf_get_lines(bufnr, sep_row, sep_row + 1, false)
    local ct    = require("jup.notebook").parse_separator(lines[1] or "") or "code"
    state = { cell_type = ct, running = false, exec_count = nil }
  end
  render_sep(bufnr, sep_row, state.cell_type, running, state.exec_count)
end

function M.set_exec_count(bufnr, sep_row, count)
  local state = (_sep_state[bufnr] or {})[sep_row]
  if not state then return end
  render_sep(bufnr, sep_row, state.cell_type, state.running, count)
end

-- ─── Output rendering ────────────────────────────────────────────────────────

--- Format a list of output objects into virt_lines entries with background.
---@param outputs table[]
---@return table[]
function M.format_outputs(outputs)
  local cfg = config.get()
  local virt = {}
  local max  = cfg.display.max_output_lines

  local function push(text, hl)
    local clean = cfg.display.strip_ansi and text:gsub("\27%[[%d;]*m", "") or text
    for _, l in ipairs(vim.split(clean, "\n", { plain = true })) do
      if max > 0 and #virt >= max then
        table.insert(virt, {
          { "  ", "JupOutputBg" },
          { " … output truncated", "Comment" },
        })
        return
      end
      -- Background gutter on left + content + trailing bg to fill the line
      table.insert(virt, {
        { "  ", "JupOutputBg" },
        { l,    hl            },
      })
    end
  end

  for _, out in ipairs(outputs) do
    local ot = out.output_type

    if ot == "stream" then
      local hl = out.name == "stderr" and "JupStderr" or "JupStdout"
      push(out.text or "", hl)

    elseif ot == "execute_result" or ot == "display_data" then
      local data = out.data or {}
      local text = data["text/plain"]
      if text then
        push(type(text) == "table" and table.concat(text, "") or text, "JupResult")
      elseif data["image/png"] or data["image/jpeg"] then
        push("[image output]", "Comment")
      end

    elseif ot == "error" then
      push(string.format("%s: %s", out.ename or "Error", out.evalue or ""), "JupError")
      for _, tb in ipairs(out.traceback or {}) do
        push(tb, "JupStderr")
      end
    end
  end

  return virt
end

--- Place or update the output extmark for a cell.
---@param bufnr integer
---@param anchor_row integer  0-indexed row; virt_lines appear below this row
---@param outputs table[]
---@param existing_id integer|nil
---@return integer extmark_id
function M.set_cell_output(bufnr, anchor_row, outputs, existing_id)
  local virt = M.format_outputs(outputs)
  local ns   = M.ns_output()
  local opts = {
    virt_lines         = virt,
    virt_lines_above   = false,
    virt_lines_leftcol = false,
    priority           = 50,
  }
  if existing_id then opts.id = existing_id end
  return vim.api.nvim_buf_set_extmark(bufnr, ns, anchor_row, 0, opts)
end

--- Convert a list of output objects to a plain text string (ANSI stripped).
---@param outputs table[]
---@return string
function M.outputs_to_text(outputs)
  local lines = {}
  local function add(text)
    text = text:gsub("\27%[[%d;]*m", "")
    for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
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
      end
    elseif ot == "error" then
      add(string.format("%s: %s", out.ename or "Error", out.evalue or ""))
      for _, tb in ipairs(out.traceback or {}) do
        add(tb)
      end
    end
  end
  return table.concat(lines, "\n")
end

function M.clear_cell_output(bufnr, extmark_id)
  if extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns_output(), extmark_id)
  end
end

function M.clear_all_outputs(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_output(), 0, -1)
end

return M
