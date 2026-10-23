-- lazy.nvim entry point for bracey.nvim
-- Defines the :Bracey* commands and initializes the module.

if vim.g.loaded_bracey == 1 then
	return
end
vim.g.loaded_bracey = 1

local bracey = require("bracey")

-- Ensure defaults exist for non-lazy users. If lazy.nvim is used with
-- `opts = { ... }`, it will call `require("bracey").setup(opts)` afterwards and
-- override these defaults.
if not bracey.config.server_port then
	bracey.setup()
end

-- Define user commands
vim.api.nvim_create_user_command("Bracey", function()
	bracey.start()
end, { nargs = 0 })

vim.api.nvim_create_user_command("BraceyStop", function()
	bracey.stop()
end, { nargs = 0 })

vim.api.nvim_create_user_command("BraceyReload", function()
	bracey.reload()
end, { nargs = 0 })

vim.api.nvim_create_user_command("BraceyEval", function(cmd)
	bracey.eval(cmd.args ~= "" and cmd.args or nil)
end, { nargs = "*" })
