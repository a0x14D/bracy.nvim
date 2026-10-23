--- Manages the Node.js bracey server process.
--- Spawns `node launch.js` in the server directory and tracks its lifetime.

local M = {}

local server_process = nil
local server_log_file = nil

---Start the node server
---@param port number
---@param allow_remote boolean
---@param server_path string
---@param log_path string|nil
---@return boolean ok, string|nil err
function M.start(port, allow_remote, server_path, log_path)
	if server_process then
		return false, "server already running"
	end

	-- compute the server dir relative to this module file:
	-- lua/bracey/server.lua  ->  ../../server  (root server/)
	local src = debug.getinfo(1, "S").source:sub(2)
	local mod_dir = src:match("^.*/")
	local server_dir = vim.fs.normalize(mod_dir .. "../../server")

	local args = { "node", "launch.js", "--port", tostring(port) }

	if allow_remote then
		table.insert(args, "--allow-remote-web")
	end

	local log_to = nil
	if log_path then
		local ok, f = pcall(io.open, log_path, "a")
		if ok then
			server_log_file = f
			log_to = server_log_file
		end
	end

	local stdio = { nil, log_to or nil, log_to or nil }
	if log_path and not log_to then
		stdio = { nil, nil, nil }
	end

	local ok, proc_or_err = pcall(vim.system, args, {
		cwd = server_dir,
		stdio = stdio,
	}, function() end)

	if not ok then
		return false, tostring(proc_or_err)
	end

	server_process = proc_or_err
	return true, nil
end

---Stop the node server
---@return boolean ok, string|nil err
function M.stop()
	if not server_process then
		return false, "server not running"
	end

	local ok, err = pcall(function()
		server_process:kill("term")
	end)

	if server_log_file then
		pcall(function()
			server_log_file:close()
		end)
		server_log_file = nil
	end

	server_process = nil

	if not ok then
		return false, tostring(err)
	end
	return true, nil
end

---Check if the server process is running
---@return boolean
function M.is_running()
	return server_process ~= nil
end

return M
