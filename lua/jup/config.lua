local M = {}

M.defaults = {
  -- Python executable used to launch the kernel bridge
  python_path = "python3",

  kernel = {
    -- Default kernel name when starting a new kernel
    default = "python3",
    -- Milliseconds to wait for kernel to become ready
    timeout = 30000,
  },

  display = {
    -- Maximum output lines shown per cell (0 = unlimited)
    max_output_lines = 100,
    -- Strip ANSI escape codes from traceback output
    strip_ansi = true,
  },

  -- Buffer-local keymaps applied when a notebook is opened.
  -- Set a key to false to disable it. Set keymaps = false to disable all.
  -- All keymaps are normal-mode and buffer-local.
  keymaps = {
    run_cell        = "<leader>jr",
    run_all         = "<leader>jR",
    run_above       = "<leader>ja",
    run_below       = "<leader>jb",
    connect         = "<leader>jc",
    disconnect      = false,
    interrupt       = "<leader>jx",
    restart         = "<leader>jX",
    kernel_info     = "<leader>ji",
    show_status     = "<leader>js",
    clear_outputs   = "<leader>jo",
    clear_cell      = "<leader>jO",
    yank_output     = "<leader>jy",
    new_cell_code   = "<leader>jn",
    new_cell_md     = "<leader>jm",
    delete_cell     = "<leader>jd",
    next_cell       = "]j",
    prev_cell       = "[j",
    save            = false,
  },
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

function M.get()
  if vim.tbl_isempty(M.options) then
    M.options = vim.deepcopy(M.defaults)
  end
  return M.options
end

return M
