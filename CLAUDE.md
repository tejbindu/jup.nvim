# jup.nvim — agent context

Neovim plugin for editing and running Jupyter notebooks. Lua frontend +
Python bridge process per buffer. See README.md for user-facing docs.

## Architecture

```
plugin/jup.lua        startup entry point
lua/jup/
  init.lua            public API + keymap registration
  buffer.lua          buffer lifecycle: load, save, scaffold
  notebook.lua        .ipynb parse/serialize + buffer format
  kernel.lua          Python bridge process manager
  output.lua          extmark rendering: borders + output
  config.lua          defaults + options
python/jup_kernel.py  kernel bridge (stdin/stdout JSON ↔ jupyter_client)
```

### Data flow

1. User opens `foo.ipynb` → `BufReadCmd` fires → `buffer.load()` parses JSON,
   writes percent-format lines into the buffer, restores outputs as virtual lines.
2. User runs a cell → `init.run_cell()` → `kernel.execute()` → message sent to
   Python bridge over stdin. Bridge sends back `output`, `execution_count`, and
   `done` events over stdout → `kernel._dispatch()` routes them → `output.set_cell_output()`
   places virtual lines.
3. User saves → `BufWriteCmd` → `buffer.save()` merges current source with
   stored cell metadata (outputs, execution_count, ids) → serializes to JSON.

### Per-buffer state

- `buffer._state[bufnr]` — path, nb metadata, `cells_meta` (outputs, execution
  counts, ids preserved from the .ipynb for round-trip fidelity)
- `kernel._state[bufnr]` — job_id, pending RPC callbacks, `cell_outputs`,
  `output_extmarks`, `cell_anchors`, `cell_sep_rows`, `on_done_cb`
- `output._sep_state[bufnr][sep_row]` — extmark id + cell_type/running/exec_count
  for each separator line (used to redraw borders without full re-scan)

## Critical implementation details

### Neovim jobstart newline handling
`on_stdout` receives data where Neovim represents newlines as **empty strings**
between list elements. Must join with `"\n"`:
```lua
st.line_buf = (st.line_buf or "") .. table.concat(data, "\n")
```
Using `""` silently drops all newlines and breaks JSON parsing — this was the
hardest bug to find.

### BufReadCmd fires for non-existent files
When a user opens a path that doesn't exist yet, `BufReadCmd` still fires.
`buffer.load()` checks `io.open` and calls `buffer._scaffold()` to create a
blank single-cell notebook rather than erroring.

### Double-load guard
Both `plugin/jup.lua` (fallback) and `setup()`'s `BufReadCmd` handler can fire.
`buffer.load()` has an early return if `_state[bufnr]` is already set.
`plugin/jup.lua`'s callback checks `vim.g.jup_nvim_setup_done` before acting.

### Sequential cell execution
`kernel._state[bufnr].on_done_cb` is a single slot — safe only because
`init._run_sequence()` waits for the callback before submitting the next cell.
Concurrent `run_cell()` calls would overwrite it.

### Cell IDs (exec vs. stored)
- **Exec ID**: `"buf{bufnr}_row{sep_row}"` — runtime only, used to route kernel
  output to the right extmark. Resets on reload.
- **Stored ID**: 8-char hex string from the `.ipynb` — preserved in
  `cells_meta` for round-trip fidelity.

## Known gaps / deferred work

- **Cell-relative line numbers**: Attempted via `statuscolumn` but caused
  `E5101: Cannot convert given lua type` from nui.nvim's border redraws.
  Completely removed for now.
- **`complete()` / `list_kernels()`**: Implemented in `python/jup_kernel.py`
  but the Lua callers were removed as dead code. Re-add Lua wrappers in
  `kernel.lua` and expose via `init.lua` if needed.
- **Concurrent execution**: Not safe — `on_done_cb` is a single slot per buffer.

## Conventions

- No global keymaps — all keymaps are buffer-local, applied in `buffer.load()`
  and `buffer._scaffold()` via `require("jup")._apply_keymaps(bufnr)`.
- Highlight groups are defined as `default = true` links so users can override
  them after `setup()` without fighting the plugin.
- `output._sep_state` uses nested tables `[bufnr][sep_row]` — never flatten
  to a single integer key (fragile with large bufnr values).
- Python bridge communicates via newline-delimited JSON. Each request has an
  integer `id`; replies carry the same `id` so callbacks can be matched.
