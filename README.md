# jup.nvim

Edit and run Jupyter notebooks in Neovim. Notebooks are displayed in a readable
percent-format, cells are bordered with extmarks, and output appears inline as
virtual lines — no browser required.

## Features

- Open and save `.ipynb` files with full round-trip fidelity
- Connect to any Jupyter kernel (`python3`, `julia`, `r`, …)
- Run cells individually or in sequence; output renders inline
- Cell borders with running indicator and execution count
- All keymaps are buffer-local and fully customizable
- `:JupConnect` tab-completes available kernel names

## Requirements

- Neovim ≥ 0.10
- Python 3 with `jupyter_client` installed (`pip install jupyter_client`)

## Installation

**lazy.nvim:**

```lua
{
  "tejbindu/jup.nvim",
  lazy = false,
  config = function()
    require("jup").setup()
  end,
}
```

## Configuration

All keys are optional — shown below with their defaults:

```lua
require("jup").setup({
  python_path = "python3",   -- Python used to launch the kernel bridge

  kernel = {
    default = "python3",     -- Kernel started when none is specified
    timeout = 30000,         -- ms to wait for kernel ready
  },

  display = {
    max_output_lines = 100,  -- Lines of output per cell (0 = unlimited)
    strip_ansi = true,       -- Strip ANSI codes from tracebacks
  },

  keymaps = {
    run_cell      = "<leader>jr",
    run_all       = "<leader>jR",
    run_above     = "<leader>ja",
    run_below     = "<leader>jb",
    connect       = "<leader>jc",
    interrupt     = "<leader>jx",
    restart       = "<leader>jX",
    kernel_info   = "<leader>ji",
    show_status   = "<leader>js",
    clear_outputs = "<leader>jo",
    clear_cell    = "<leader>jO",
    new_cell_code = "<leader>jn",
    new_cell_md   = "<leader>jm",
    delete_cell   = "<leader>jd",
    next_cell     = "]j",
    prev_cell     = "[j",
    -- Set a key to false to disable it, or keymaps = false to disable all.
  },
})
```

## Commands

| Command | Description |
|---|---|
| `:JupConnect [name\|file.json]` | Start or connect to a kernel |
| `:JupDisconnect` | Stop the kernel bridge |
| `:JupRun` | Execute cell under cursor |
| `:JupRunAll` | Execute all cells in order |
| `:JupRunAbove` | Execute all cells above cursor |
| `:JupRunBelow` | Execute current cell and below |
| `:JupInterrupt` | Interrupt a running kernel |
| `:JupRestart` | Restart the kernel |
| `:JupKernelInfo` | Show kernel language and version |
| `:JupStatus` | Show connection status |
| `:JupClearOutputs` | Clear all cell outputs |
| `:JupClearCell` | Clear output of current cell |
| `:JupNewCell [code\|markdown\|raw]` | Insert a new cell below |
| `:JupDeleteCell` | Delete the current cell |
| `:JupSave` | Save notebook to `.ipynb` |

## Buffer format

Notebooks are rendered using the percent format, compatible with
[Jupytext](https://github.com/mwouts/jupytext):

```python
# %%
x = 1 + 1
print(x)

# %% [markdown]
## My heading

Some *markdown* text.
```

The `# %%` separator lines are hidden behind cell-border decorations. Outputs
are shown as virtual lines below each cell and are not part of the buffer text.

## Lua API

```lua
local jup = require("jup")

jup.connect()            -- connect to default kernel
jup.disconnect()         -- stop the bridge
jup.restart()            -- restart the kernel
jup.interrupt()          -- interrupt execution
jup.kernel_info()        -- notify with kernel language/version
jup.is_connected()       -- returns bool (useful for statusline)

jup.run_cell()           -- run cell under cursor
jup.run_all()            -- run all cells
jup.run_above()          -- run cells above cursor
jup.run_below()          -- run current and below

jup.clear_outputs()      -- clear all outputs
jup.clear_cell_output()  -- clear current cell output

jup.new_cell("code")     -- insert code cell below
jup.new_cell("markdown") -- insert markdown cell below
jup.delete_cell()        -- delete current cell

jup.goto_next_cell()     -- move cursor to next cell
jup.goto_prev_cell()     -- move cursor to previous cell

jup.save()               -- save notebook
jup.show_status()        -- show file + kernel status
```

## Architecture

```
plugin/jup.lua        startup entry point (BufReadCmd fallback)
lua/jup/
  init.lua            public API + keymap registration
  buffer.lua          buffer lifecycle: load, save, scaffold
  notebook.lua        .ipynb parse/serialize + buffer format
  kernel.lua          Python bridge process manager
  output.lua          extmark rendering: borders + output
  config.lua          defaults + options
python/jup_kernel.py  kernel bridge (stdin/stdout JSON ↔ jupyter_client)
```

## License

MIT
