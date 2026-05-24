-- plugin/jup.lua — loaded once on Neovim startup.
if vim.g.loaded_jup_nvim then return end
vim.g.loaded_jup_nvim = true

-- Fallback: if the user never calls require("jup").setup() in their config,
-- auto-setup on the first .ipynb open and manually trigger the load (since we
-- are already inside BufReadCmd and the newly-registered autocmd won't re-fire).
--
-- When setup() WAS called already (lazy = false + config block), this callback
-- still fires but does nothing — the group BufReadCmd registered by setup()
-- handles the actual load.
vim.api.nvim_create_autocmd("BufReadCmd", {
  pattern  = "*.ipynb",
  once     = true,
  callback = function(ev)
    if not vim.g.jup_nvim_setup_done then
      require("jup").setup({})
      require("jup.buffer").load(ev.buf, vim.fn.fnamemodify(ev.match, ":p"))
    end
    -- If setup was already done, the BufReadCmd in the jup_global group handles it.
  end,
})
