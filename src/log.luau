--!strict
--[[
	Timestamped logging to stdout and, optionally, a file.

	The file sink exists because stdout is block-buffered whenever it is not a
	terminal -- which is every way you would actually run this: under nohup,
	behind a tunnel, from a service manager. Without it, a panel that crashed
	an hour ago still shows an empty log, which is precisely when you need it.
	Each line is opened, appended and closed so nothing is ever held back.
]]
local fs = require("@lute/fs")

local Log = {}

local LEVELS = { debug = 10, info = 20, warn = 30, error = 40 }
local threshold = LEVELS.info
local filePath: string? = nil

function Log.setLevel(level: string)
	threshold = LEVELS[level] or LEVELS.info
end

function Log.setFile(path: string?)
	filePath = path
end

local function emit(level: string, message: string)
	if (LEVELS[level] or 0) < threshold then
		return
	end
	local line = `{os.date("!%Y-%m-%dT%H:%M:%SZ")} {level:upper()} {message}`
	print(line)
	local target = filePath
	if target ~= nil then
		-- Failing to log must never take the server down, so this is best
		-- effort and deliberately silent on error.
		pcall(function()
			-- Lute's "a" refuses to create the file, so an absent log has to
			-- be opened "w" once first. "rw" is NOT a substitute: it writes
			-- from offset zero and silently overwrites.
			local handle = fs.open(target, if fs.exists(target) then "a" else "w")
			fs.write(handle, line .. "\n")
			fs.close(handle)
		end)
	end
end

function Log.debug(message: string) emit("debug", message) end
function Log.info(message: string) emit("info", message) end
function Log.warn(message: string) emit("warn", message) end
function Log.error(message: string) emit("error", message) end

return Log
