-- Handles .ipynb JSON parsing/serialization and buffer cell format.
--
-- Buffer format uses percent-format cell delimiters:
--   # %%
--   python code here
--
--   # %% [markdown]
--   markdown content here
--
-- Output blocks are stored as real buffer lines between the source and
-- the next cell separator:
--   # %%
--   print(x)
--   # %% [out]
--   42
--
--   # %% [markdown]

local M = {}

local OUTPUT_SEP = "# %% [out]"

local _cell_id_counter = 0
local function new_cell_id()
  _cell_id_counter = _cell_id_counter + 1
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

--- Convert a notebook model to buffer lines (no output blocks; those are added
--- separately by buffer._restore_outputs).
---@param notebook table
---@return string[] lines
function M.notebook_to_lines(notebook)
  local out = {}
  for i, cell in ipairs(notebook.cells) do
    table.insert(out, M.make_separator(cell.cell_type))

    local src = cell.source:gsub("\n$", "")
    for _, l in ipairs(vim.split(src, "\n", { plain = true })) do
      table.insert(out, l)
    end

    if i < #notebook.cells then
      table.insert(out, "")
    end
  end
  return out
end

--- Parse buffer lines back to a list of cell objects.
--- Output blocks (# %% [out]) are excluded from source but tracked as
--- output_sep_row / output_end_row on the preceding code cell.
---@param lines string[]
---@return table[] cells  each has: cell_type, source, sep_row, source_end_row,
---                       end_row, output_sep_row (nil if none), output_end_row (nil if none),
---                       cell_index (1-based)
function M.lines_to_cells(lines)
  local cells    = {}
  local current  = nil
  local src_lines = {}
  local src_rows  = {}   -- 0-indexed row for each entry in src_lines
  local out_lines = {}   -- {row, line} for output block content
  local in_output = false

  local function flush(next_row)
    if not current then return end

    -- Trim trailing blank lines from source
    while #src_lines > 0 and src_lines[#src_lines] == "" do
      table.remove(src_lines)
      table.remove(src_rows)
    end
    current.source  = table.concat(src_lines, "\n")
    current.end_row = (next_row or (#lines)) - 1

    if not current.output_sep_row then
      -- No output block: source_end_row is the last non-blank source row
      current.source_end_row = src_rows[#src_rows] or current.sep_row
    end
    -- (source_end_row is already set when we first see # %% [out])

    -- Trim trailing blank lines from output content
    while #out_lines > 0 and out_lines[#out_lines].line == "" do
      table.remove(out_lines)
    end
    if current.output_sep_row then
      current.output_end_row = #out_lines > 0
        and out_lines[#out_lines].row
        or current.output_sep_row  -- empty block: just the separator line itself
    end

    table.insert(cells, current)
    src_lines = {}
    src_rows  = {}
    out_lines = {}
    in_output = false
  end

  for i, line in ipairs(lines) do
    local row = i - 1   -- 0-indexed
    if line == OUTPUT_SEP then
      if current and not in_output then
        -- Record source_end_row as the last non-blank source row seen so far
        local last_nonblank = current.sep_row
        for j = #src_lines, 1, -1 do
          if src_lines[j] ~= "" then
            last_nonblank = src_rows[j]
            break
          end
        end
        current.source_end_row = last_nonblank
        current.output_sep_row = row
        in_output = true
      end
    else
      local cell_type = M.parse_separator(line)
      if cell_type then
        in_output = false
        flush(row)
        current = { cell_type = cell_type, sep_row = row }
      elseif current then
        if in_output then
          table.insert(out_lines, { row = row, line = line })
        else
          table.insert(src_lines, line)
          table.insert(src_rows, row)
        end
      end
    end
  end
  flush(nil)

  for i, c in ipairs(cells) do c.cell_index = i end
  return cells
end

--- Return cell_type if `line` is a cell separator, otherwise nil.
--- Returns nil for output block separators (# %% [out]).
---@param line string
---@return string|nil cell_type  "code" | "markdown" | "raw" | nil
function M.parse_separator(line)
  local rest = line:match("^# %%%% ?(.*)")
  if rest == nil then return nil end

  local t = rest:match("%[([^%]]+)%]") or rest:match("^(%a+)") or ""
  t = t:lower():gsub("^%s+", ""):gsub("%s+$", "")
  if t == "markdown" or t == "md" then return "markdown"
  elseif t == "raw"                then return "raw"
  elseif t == "out"                then return nil   -- output block, not a cell
  else                              return "code"
  end
end

--- Given a bufnr and a 0-indexed cursor row, return info about the containing cell.
---@param bufnr integer
---@param cursor_row integer 0-indexed
---@return table|nil  {cell_type, sep_row, source_end_row, end_row, output_sep_row, output_end_row, cell_index}
function M.cell_at_row(bufnr, cursor_row)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cells = M.lines_to_cells(lines)
  for _, c in ipairs(cells) do
    if cursor_row >= c.sep_row and cursor_row <= c.end_row then
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

function M.make_output_separator()
  return OUTPUT_SEP
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
