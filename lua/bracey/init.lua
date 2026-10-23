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

---@type boolean
M._ready = false

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

-- Internal: extract the host from a server path like "http://127.0.0.1"
---@param server_path string
---@return string
local function server_host(server_path)
	local host = server_path:gsub("^https?://", "")
	host = host:gsub("/.*$", "")
	return host ~= "" and host or "127.0.0.1"
end

-- Internal: wait until the node server answers its per-session health probe.
-- This is stronger than a TCP connect: it proves the process listening on the
-- port is *our* server (matching token), not some unrelated service.
---@param host string
---@param port number
---@param token string
---@param timeout_ms number
---@param callback fun(ok: boolean, reason?: string)
function M.wait_for_health(host, port, token, timeout_ms, callback)
	local url = ("http://%s:%d/__bracey_health"):format(host, port)
	local deadline = vim.uv.now() + timeout_ms
	local finished = false

	local function finish(ok, reason)
		if finished then
			return
		end
		finished = true
		callback(ok, reason)
	end

	local function attempt()
		if finished then
			return
		end
		if not M._running then
			return finish(false, "stopped")
		end
		if M._server and not M._server.is_running() then
			return finish(false, "exited")
		end

		vim.system({ "curl", "-s", "--connect-timeout", "0.5", "--max-time", "1", url }, {}, function(res)
			vim.schedule(function()
				if finished then
					return
				end
				if res.code == 0 and vim.trim(res.stdout or "") == token then
					return finish(true)
				end
				if M._server and not M._server.is_running() then
					return finish(false, "exited")
				end
				if vim.uv.now() >= deadline then
					return finish(false, "timeout")
				end
				vim.defer_fn(attempt, 100)
			end)
		end)
	end

	attempt()
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
	local server = require("bracey.server")
	local host = server_host(cfg.server_path)

	-- Unique token for this session. The health probe only succeeds when the
	-- process answering on the port is the one we just spawned.
	local token = ("%d-%d"):format(os.time(), vim.uv.hrtime())

	local base_port = cfg.server_port
	local max_attempts = 20

	M._ready = false
	M._running = true

	local function after_ready()
		if not M._running then
			return
		end
		M._ready = true
		M.setup_handlers()
		M.set_vars()
		M.set_file()

		if cfg.auto_start_browser then
			M.start_browser(cfg.server_path .. ":" .. tostring(M._port))
		end
	end

	local function fail(port, detail)
		M.stop()
		vim.notify(
			("bracey: server did not start on %s:%d%s"):format(host, port, detail and ("\n" .. detail) or ""),
			vim.log.levels.ERROR
		)
	end

	local attempt_start
	attempt_start = function(port, attempt)
		if not M._running then
			return
		end
		if attempt > max_attempts or port > 65535 then
			fail(port, "no free port found")
			return
		end

		M._port = port

		local ok, err = server.start({
			port = port,
			allow_remote = cfg.server_allow_remote_connections,
			log = cfg.server_log,
			token = token,
			on_exit = function(info)
				-- Only warn if the session had already been announced as ready;
				-- startup failures are handled by the readiness check below.
				local was_ready = M._ready
				M._ready = false
				if was_ready then
					M._running = false
					vim.schedule(function()
						vim.notify("bracey: server exited: " .. server.describe_exit(info), vim.log.levels.ERROR)
					end)
				end
			end,
		})

		if not ok then
			M._running = false
			vim.notify("bracey: could not start server: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		M._server = server

		-- Never open the browser before the server answers with our token.
		M.wait_for_health(host, port, token, 5000, function(ready)
			if ready then
				after_ready()
				return
			end

			local detail = server.last_error()
			local alive = server.is_running()
			server.stop()
			M._server = nil

			-- The port was taken (by a stale bracey server, another program, or
			-- something that accepts connections but is not ours). Move on to
			-- the next port instead of opening a browser onto a dead address.
			if not alive and detail and detail:find("EADDRINUSE", 1, true) then
				vim.notify(("bracey: port %d is in use, trying %d"):format(port, port + 1), vim.log.levels.WARN)
				attempt_start(port + 1, attempt + 1)
				return
			end

			fail(port, detail)
		end)
	end

	if cfg.auto_start_server then
		attempt_start(base_port, 1)
	else
		M._port = base_port
		after_ready()
	end
end

-- Stop bracey
function M.stop()
	if M._server then
		M._server.stop()
		M._server = nil
	end
	M._running = false
	M._ready = false
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
