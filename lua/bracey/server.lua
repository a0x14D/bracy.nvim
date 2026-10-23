--- Manages the Node.js bracey server process.
--- Spawns `node launch.js` in the server directory and tracks its lifetime.

local M = {}

---@type vim.SystemObj|nil
local server_process = nil

---@type string|nil
local server_log_path = nil

---@type boolean
local stopping = false

---@type table|nil
local exit_info = nil

---@type fun(info: table)|nil
local exit_callback = nil

-- Incremented on every start/stop so callbacks from a previous process (e.g.
-- the crashed attempt we are retrying) are ignored.
local generation = 0

---Absolute path to the bundled node server directory.
---lua/bracey/server.lua  ->  ../../server
---@return string
function M.server_dir()
	local src = debug.getinfo(1, "S").source:sub(2)
	local mod_dir = src:match("^.*/") or "./"
	return vim.fs.normalize(mod_dir .. "../../server")
end

-- Append text to the configured log file (best effort).
---@param text string|nil
local function write_log(text)
	if not server_log_path or not text or text == "" then
		return
	end
	local ok, f = pcall(io.open, server_log_path, "a")
	if not ok or not f then
		return
	end
	f:write(text)
	if text:sub(-1) ~= "\n" then
		f:write("\n")
	end
	f:close()
end

---Human readable description of a process exit.
---@param info table
---@return string
function M.describe_exit(info)
	if not info then
		return "unknown error"
	end
	local parts = {}
	if info.stderr and info.stderr ~= "" then
		table.insert(parts, vim.trim(info.stderr))
	end
	if info.stdout and info.stdout ~= "" then
		table.insert(parts, vim.trim(info.stdout))
	end
	if #parts > 0 then
		return table.concat(parts, "\n")
	end
	if info.signal and info.signal ~= 0 then
		return ("server terminated by signal %d"):format(info.signal)
	end
	return ("server exited with code %s"):format(tostring(info.code))
end

---Start the node server.
---@param opts { port: number, allow_remote?: boolean, log?: string|nil, token?: string|nil, on_exit?: fun(info: table)|nil }
---@return boolean ok, string|nil err
function M.start(opts)
	opts = opts or {}
	if server_process then
		return false, "server already running"
	end

	local dir = M.server_dir()
	if vim.uv.fs_stat(dir .. "/launch.js") == nil then
		return false, "server not found at " .. dir
	end

	local args = { "node", "launch.js", "--port", tostring(opts.port) }
	if opts.allow_remote then
		table.insert(args, "--allow-remote-web")
	end
	if opts.token and opts.token ~= "" then
		table.insert(args, "--token")
		table.insert(args, opts.token)
	end

	stopping = false
	exit_info = nil
	exit_callback = opts.on_exit
	server_log_path = opts.log
	generation = generation + 1
	local this_generation = generation

	-- Use the default stdio (pipes). Output is captured on exit, which is what
	-- we need to explain a failed startup. File-handle based stdio is not
	-- reliable across Neovim versions.
	local ok, proc_or_err = pcall(vim.system, args, {
		cwd = dir,
	}, function(res)
		if this_generation ~= generation then
			return
		end
		exit_info = {
			code = res.code,
			signal = res.signal,
			stdout = res.stdout,
			stderr = res.stderr,
		}
		write_log((res.stdout or "") .. (res.stderr or ""))
		server_process = nil
		if not stopping and exit_callback then
			exit_callback(exit_info)
		end
	end)

	if not ok then
		return false, tostring(proc_or_err)
	end

	server_process = proc_or_err
	return true, nil
end

---Description of the last server error, if it exited.
---@return string|nil
function M.last_error()
	if not exit_info then
		return nil
	end
	return M.describe_exit(exit_info)
end

---Stop the node server.
---@return boolean ok, string|nil err
function M.stop()
	if not server_process then
		return false, "server not running"
	end

	local proc = server_process
	stopping = true
	generation = generation + 1 -- invalidate callbacks from this process

	-- NOTE: libuv signal names are "sigterm"/"sigkill"; the bare "term" is not
	-- recognised and silently does nothing.
	local ok, err = pcall(function()
		proc:kill("sigterm")
	end)

	-- Give node a moment to shut down, then force kill if needed.
	pcall(function()
		proc:wait(1000)
	end)
	pcall(function()
		proc:kill("sigkill")
	end)

	server_process = nil

	if not ok then
		return false, tostring(err)
	end
	return true, nil
end

---Check if the server process is running.
---@return boolean
function M.is_running()
	return server_process ~= nil
end

return M
