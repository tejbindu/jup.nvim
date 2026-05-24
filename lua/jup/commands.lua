-- Registers all :Jup* user commands.
-- Every command delegates to the public API in jup.init.

local M = {}

function M.setup()
  local api = require("jup")

  -- ── Kernel lifecycle ───────────────────────────────────────────────────────

  vim.api.nvim_create_user_command("JupConnect", function(opts)
    local arg = opts.args ~= "" and opts.args or nil
    if arg and arg:match("%.json$") then
      api.connect({ connection_file = arg })
    else
      api.connect({ kernel_name = arg })
    end
  end, {
    nargs = "?",
    complete = function()
      -- Query jupyter directly — no bridge required, works synchronously
      local out = vim.fn.system("jupyter kernelspec list --json 2>/dev/null")
      if vim.v.shell_error ~= 0 then return {} end
      local ok, data = pcall(vim.fn.json_decode, out)
      if not ok or type(data) ~= "table" then return {} end
      local names = {}
      for name in pairs(data.kernelspecs or {}) do
        table.insert(names, name)
      end
      table.sort(names)
      return names
    end,
    desc = "Connect to or start a Jupyter kernel [:JupConnect [kernel_name|connection.json]]",
  })

  vim.api.nvim_create_user_command("JupDisconnect", function()
    api.disconnect()
  end, { desc = "Stop the kernel bridge for this notebook" })

  vim.api.nvim_create_user_command("JupRestart", function()
    api.restart()
  end, { desc = "Restart the kernel" })

  vim.api.nvim_create_user_command("JupInterrupt", function()
    api.interrupt()
  end, { desc = "Interrupt kernel execution" })

  vim.api.nvim_create_user_command("JupKernelInfo", function()
    api.kernel_info()
  end, { desc = "Show kernel information" })

  -- ── Cell execution ─────────────────────────────────────────────────────────

  vim.api.nvim_create_user_command("JupRun", function()
    api.run_cell()
  end, { desc = "Execute the cell under the cursor" })

  vim.api.nvim_create_user_command("JupRunAll", function()
    api.run_all()
  end, { desc = "Execute all cells in order" })

  vim.api.nvim_create_user_command("JupRunAbove", function()
    api.run_above()
  end, { desc = "Execute all cells above the cursor" })

  vim.api.nvim_create_user_command("JupRunBelow", function()
    api.run_below()
  end, { desc = "Execute current cell and all below" })

  -- ── Output management ──────────────────────────────────────────────────────

  vim.api.nvim_create_user_command("JupClearOutputs", function()
    api.clear_outputs()
  end, { desc = "Clear all cell outputs" })

  vim.api.nvim_create_user_command("JupClearCell", function()
    api.clear_cell_output()
  end, { desc = "Clear output of cell under cursor" })

  -- ── Cell navigation / editing ──────────────────────────────────────────────

  vim.api.nvim_create_user_command("JupNextCell", function()
    api.goto_next_cell()
  end, { desc = "Move cursor to next cell" })

  vim.api.nvim_create_user_command("JupPrevCell", function()
    api.goto_prev_cell()
  end, { desc = "Move cursor to previous cell" })

  vim.api.nvim_create_user_command("JupNewCell", function(opts)
    local type_ = opts.args ~= "" and opts.args or "code"
    api.new_cell(type_)
  end, {
    nargs = "?",
    complete = function() return { "code", "markdown", "raw" } end,
    desc = "Insert a new cell below the cursor [:JupNewCell [code|markdown|raw]]",
  })

  vim.api.nvim_create_user_command("JupDeleteCell", function()
    api.delete_cell()
  end, { desc = "Delete the cell under the cursor" })

  -- ── Save ──────────────────────────────────────────────────────────────────

  vim.api.nvim_create_user_command("JupSave", function()
    api.save()
  end, { desc = "Save the notebook back to .ipynb" })

  -- ── Status ────────────────────────────────────────────────────────────────

  vim.api.nvim_create_user_command("JupStatus", function()
    api.show_status()
  end, { desc = "Show kernel connection status" })
end

return M
