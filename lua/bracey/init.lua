---@class bracey.Config
---@field browser_command string|number 0 = auto (xdg-open/open)
---@field auto_start_browser boolean
---@field refresh_on_save boolean
---@field eval_on_save boolean
---@field auto_start_server boolean
---@field server_allow_remote_connections boolean
---@field server_port number
---@field server_path string
---@field server_log string|nil

---@type bracey.Config
local defaults = {
	browser_command = 0,
	auto_start_browser = true,
	refresh_on_save = false,
	eval_on_save = true,
	auto_start_server = true,
	server_allow_remote_connections = false,
	server_port = nil, -- nil => random derived from pid
	server_path = "http://127.0.0.1",
	server_log = nil,
}

local M = {}

---@type bracey.Config
M.config = {}

---@type table|nil
M._server = nil

---@type number|nil
M._port = nil

---@type boolean
M._running = false

-- Resolve effective config with defaults filled in
function M.resolve_config(opts)
	opts = opts or {}
	local cfg = {}

	-- start from defaults (explicit copy so false booleans are preserved)
	for k, v in pairs(defaults) do
		cfg[k] = v
	end

	-- overlay user options (pairs preserves explicit false values)
	for k, v in pairs(opts) do
		cfg[k] = v
	end

	if cfg.server_port == nil then
		-- random-ish port derived from pid (same as old vimscript)
		local offset = 13378
		local port_max = 65536
		cfg.server_port = offset + (vim.fn.getpid() % (port_max - offset))
	end
	return cfg
end

---Setup bracey.nvim
---@param opts? bracey.Config
function M.setup(opts)
	M.config = M.resolve_config(opts)

	-- Expose config as a vim variable for documentation parity
	vim.g.bracey_config = M.config
end

-- Internal: build the HTTP base URL
function M.base_url()
	return M.config.server_path .. ":" .. tostring(M._port or M.config.server_port)
end

-- Internal: send an HTTP POST to the node server
---@param path string
---@param body string
---@param callback? fun(err: string|nil, res: table|nil)
function M.http_post(path, body, callback)
	local url = M.base_url() .. path
	local cmd = {
		"curl",
		"-s",
		"-X",
		"POST",
		"--data-binary",
		body,
		"-H",
		"Content-Type: application/octet-stream",
		url,
	}
	vim.system(cmd, {}, function(res)
		if not callback then
			return
		end
		if res.code ~= 0 then
			callback("curl failed: " .. (res.stderr or ""), nil)
			return
		end
		callback(nil, { code = res.code, stdout = res.stdout })
	end)
end

-- Internal: send an editor command to the server (protocol: c:len:data:len:data...)
--- Each arg is a raw string; this function prefixes it with its length.
---@param command string
---@param args string[]
---@param callback? fun(err: string|nil)
function M.send_command(command, args, callback)
	local parts = { command }
	for _, arg in ipairs(args) do
		table.insert(parts, tostring(#arg) .. ":" .. arg)
	end
	local msg = table.concat(parts, ":")
	M.http_post("/", msg, function(err, res)
		if callback then
			callback(err)
		end
	end)
end

-- Low-level: send a fully-formatted protocol message string
---@param msg string
---@param callback? fun(err: string|nil)
function M.send_raw(msg, callback)
	M.http_post("/", msg, callback)
end

-- Get current buffer content as a single string
local function buffer_content(bufnr)
	bufnr = bufnr or 0
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return table.concat(lines, "\n")
end

-- Get current file path
local function current_file_path()
	return vim.fn.expand("%:p")
end

-- Get current buffer name
local function current_bufname()
	return vim.api.nvim_buf_get_name(0)
end

-- Get current buffer number
local function current_bufnr()
	return vim.api.nvim_get_current_buf()
end

-- Start the browser
function M.start_browser(url)
	local cmd = M.config.browser_command
	if type(cmd) == "number" and cmd == 0 then
		if vim.fn.has("unix") == 1 then
			local uname = vim.fn.system("uname -s"):gsub("%s+", "")
			if uname == "Darwin" then
				vim.fn.system("open " .. vim.fn.shellescape(url) .. " &")
			else
				vim.fn.system("xdg-open " .. vim.fn.shellescape(url) .. " &")
			end
		end
	elseif type(cmd) == "string" then
		vim.fn.system(cmd .. " " .. vim.fn.shellescape(url) .. " &")
	end
end

-- Start bracey (server + handlers)
function M.start()
	if M._running then
		vim.notify("bracey: already running", vim.log.levels.WARN)
		return
	end

	-- ensure defaults exist even if setup() was never called
	if not M.config.server_port then
		M.config = M.resolve_config()
	end

	local cfg = M.config
	M._port = cfg.server_port

	-- Launch node server (if configured to do so)
	if cfg.auto_start_server then
		local server = require("bracey.server")
		local ok, err = server.start(M._port, cfg.server_allow_remote_connections, cfg.server_path, cfg.server_log)
		if not ok then
			vim.notify("bracey: could not start server: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		M._server = server
	end

	M._running = true

	-- Wait briefly for the server to bind, then set up handlers
	vim.defer_fn(function()
		M.setup_handlers()
		M.set_vars()
		M.set_file()

		if cfg.auto_start_browser then
			M.start_browser(cfg.server_path .. ":" .. tostring(M._port))
		end
	end, 1000)
end

-- Stop bracey
function M.stop()
	if not M._running then
		return
	end
	if M._server then
		local ok, err = M._server.stop()
		if not ok then
			vim.notify("bracey: stop error: " .. tostring(err), vim.log.levels.ERROR)
		end
		M._server = nil
	end
	M._running = false
end

-- Reload the current page
function M.reload()
	local path = current_file_path()
	M.send_command("r", { path }, function(err)
		if err then
			vim.notify("bracey: reload failed: " .. err, vim.log.levels.ERROR)
		end
	end)
end

-- Evaluate JavaScript in the browser
---@param js? string
function M.eval(js)
	if not js then
		js = buffer_content()
	end
	M.send_command("e", { js }, function(err)
		if err then
			vim.notify("bracey: eval failed: " .. err, vim.log.levels.ERROR)
		end
	end)
end

-- Set variables (editor root) on the server
function M.set_vars()
	local cwd = vim.fn.getcwd()
	M.send_command("v", { cwd })
end

-- Set the current file on the server
function M.set_file()
	local path = current_file_path()
	local bufname = current_bufname()
	local bufnum = tostring(current_bufnr())
	local contents = buffer_content()
	local ft = vim.bo.filetype

	-- Matches the original protocol: f:len:bufnum:len:bufname:len:path:len:ft:ftb:len:contents
	local msg = "f:" .. #bufnum .. ":" .. bufnum
		.. ":" .. #bufname .. ":" .. bufname
		.. ":" .. #path .. ":" .. path
		.. ":" .. #ft .. ":" .. ft
		.. "b:" .. #contents .. ":" .. contents
	M.send_raw(msg)
end

-- Send current buffer content (full buffer update)
function M.send_current_buffer()
	local contents = buffer_content()
	M.send_command("b", { contents })
end

-- Set cursor position (used for CSS selector highlighting)
function M.set_cursor()
	local line = tostring(vim.fn.line("."))
	local column = tostring(vim.fn.col("."))
	M.send_command("p", { line, column })
end

-- Setup autocmd handlers
function M.setup_handlers()
	local group = vim.api.nvim_create_augroup("Bracey", { clear = true })

	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = group,
		pattern = { "*.html", "*.css" },
		callback = M.set_cursor,
	})

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		pattern = { "*.html", "*.css" },
		callback = M.send_current_buffer,
	})

	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		pattern = "*",
		callback = M.set_file,
	})

	if M.config.eval_on_save then
		vim.api.nvim_create_autocmd("BufWritePost", {
			group = group,
			pattern = "*.js",
			callback = function()
				M.eval()
			end,
		})
	end

	if M.config.refresh_on_save then
		vim.api.nvim_create_autocmd("BufWritePost", {
			group = group,
			pattern = "*.html",
			callback = M.reload,
		})
	end

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = M.stop,
	})
end

return M
