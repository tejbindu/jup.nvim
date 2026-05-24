-- Handles .ipynb JSON parsing/serialization and buffer cell format.
--
-- Buffer format uses percent-format cell delimiters:
--   # %%
--   python code here
--
--   # %% [markdown]
--   markdown content here
--
-- Outputs are stored in buf-state and shown only via virtual lines.

local M = {}

local _cell_id_counter = 0
local function new_cell_id()
  _cell_id_counter = _cell_id_counter + 1
  -- Simple 8-char hex-ish ID compatible with nbformat 4.5
  return string.format("%08x", _cell_id_counter + os.time())
end

-- ─── .ipynb parse ────────────────────────────────────────────────────────────

--- Parse raw .ipynb JSON into our internal notebook model.
---@param content string raw file content
---@return table notebook
function M.parse_ipynb(content)
  local ok, data = pcall(vim.fn.json_decode, content)
  if not ok or type(data) ~= "table" then
    error("jup.nvim: failed to parse .ipynb JSON: " .. tostring(data))
  end

  local notebook = {
    metadata      = data.metadata or {},
    nbformat      = data.nbformat or 4,
    nbformat_minor = data.nbformat_minor or 5,
    cells         = {},
  }

  for _, raw in ipairs(data.cells or {}) do
    table.insert(notebook.cells, {
      id              = raw.id or new_cell_id(),
      cell_type       = raw.cell_type or "code",
      source          = M._join_source(raw.source),
      metadata        = raw.metadata or {},
      outputs         = raw.outputs or {},
      execution_count = raw.execution_count,
    })
  end

  return notebook
end

--- Serialize our internal notebook model back to .ipynb JSON.
---@param notebook table
---@return string json
function M.serialize_ipynb(notebook)
  local data = {
    metadata       = notebook.metadata,
    nbformat       = notebook.nbformat,
    nbformat_minor = notebook.nbformat_minor,
    cells          = {},
  }

  for _, cell in ipairs(notebook.cells) do
    local raw = {
      id        = cell.id or new_cell_id(),
      cell_type = cell.cell_type,
      source    = M._split_source(cell.source),
      metadata  = cell.metadata or {},
    }
    if cell.cell_type == "code" then
      raw.outputs         = cell.outputs or {}
      raw.execution_count = cell.execution_count
    end
    table.insert(data.cells, raw)
  end

  return vim.fn.json_encode(data)
end

-- ─── Buffer format ────────────────────────────────────────────────────────────

--- Convert a notebook model to buffer lines.
---@param notebook table
---@return string[] lines
function M.notebook_to_lines(notebook)
  local out = {}
  for i, cell in ipairs(notebook.cells) do
    -- Separator line
    table.insert(out, M.make_separator(cell.cell_type))

    -- Source lines (trailing newline stripped since lines are split)
    local src = cell.source:gsub("\n$", "")
    for _, l in ipairs(vim.split(src, "\n", { plain = true })) do
      table.insert(out, l)
    end

    -- Blank line between cells for readability
    if i < #notebook.cells then
      table.insert(out, "")
    end
  end
  return out
end

--- Parse buffer lines back to a list of cell objects (no outputs/meta, source only).
---@param lines string[]
---@return table[] cells  each has .cell_type, .source, .sep_row (0-indexed)
function M.lines_to_cells(lines)
  local cells = {}
  local current = nil
  local src_lines = {}

  local function flush(next_row)
    if not current then return end
    -- Trim trailing blank lines from source
    while #src_lines > 0 and src_lines[#src_lines] == "" do
      table.remove(src_lines)
    end
    current.source   = table.concat(src_lines, "\n")
    current.end_row  = (next_row or (#lines)) - 1  -- inclusive, 0-indexed
    table.insert(cells, current)
    src_lines = {}
  end

  for i, line in ipairs(lines) do
    local row = i - 1  -- 0-indexed
    local cell_type = M.parse_separator(line)
    if cell_type then
      flush(row)
      current = { cell_type = cell_type, sep_row = row }
    elseif current then
      table.insert(src_lines, line)
    end
  end
  flush(nil)

  return cells
end

--- Return cell_type if `line` is a cell separator, otherwise nil.
---@param line string
---@return string|nil cell_type  "code" | "markdown" | "raw" | nil
function M.parse_separator(line)
  -- Matches:  # %%  optionally followed by  [type]  or  type
  local rest = line:match("^# %%%% ?(.*)")
  if rest == nil then return nil end

  local t = rest:match("%[([^%]]+)%]") or rest:match("^(%a+)") or ""
  t = t:lower():gsub("^%s+", ""):gsub("%s+$", "")
  if t == "markdown" or t == "md" then return "markdown"
  elseif t == "raw"                then return "raw"
  else                              return "code"
  end
end

--- Given a bufnr and a 0-indexed cursor row, return info about the containing cell.
---@param bufnr integer
---@param cursor_row integer 0-indexed
---@return table|nil  {cell_type, sep_row, end_row, cell_index}
function M.cell_at_row(bufnr, cursor_row)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cells = M.lines_to_cells(lines)
  for i, c in ipairs(cells) do
    if cursor_row >= c.sep_row and cursor_row <= c.end_row then
      c.cell_index = i
      return c
    end
  end
  return nil
end

-- ─── Helpers ─────────────────────────────────────────────────────────────────

function M.make_separator(cell_type)
  if cell_type == "markdown" then return "# %% [markdown]"
  elseif cell_type == "raw"  then return "# %% [raw]"
  else                            return "# %%"
  end
end

function M._join_source(src)
  if type(src) == "string" then return src end
  if type(src) == "table"  then return table.concat(src, "") end
  return ""
end

function M._split_source(src)
  if src == "" then return {} end
  local result = {}
  local lines = vim.split(src, "\n", { plain = true })
  for i, l in ipairs(lines) do
    table.insert(result, i < #lines and (l .. "\n") or l)
  end
  return result
end

return M
