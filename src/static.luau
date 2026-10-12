--!strict
--[[
	Static file serving for ./public.

	Files are read once and held in memory. A public directory is a
	stylesheet and a few images, so this costs nothing and removes disk I/O
	from every page load -- but it does mean edits need a restart, which is
	the right trade for a server you leave running.
]]
local fs = require("@lute/fs")
local Response = require("@web/response")
local Log = require("@web/log")

local Static = {}

local TYPES: { [string]: string } = {
	css = "text/css; charset=utf-8",
	js = "text/javascript; charset=utf-8",
	svg = "image/svg+xml",
	png = "image/png",
	ico = "image/x-icon",
	woff2 = "font/woff2",
}

local cache: { [string]: { body: string, contentType: string } } = {}

function Static.load(root: string)
	cache = {}
	if not fs.exists(root) then
		Log.warn(`static: {root} does not exist`)
		return
	end
	for _, entry in fs.listdir(root) do
		local name = (entry :: any).name or tostring(entry)
		local full = `{root}/{name}`
		if fs.type(full) ~= "file" then
			continue
		end
		local extension = name:match("%.([%w]+)$")
		local ok, contents = pcall(function()
			local handle = fs.open(full, "r")
			local text = fs.read(handle)
			fs.close(handle)
			return text
		end)
		if ok then
			cache[name] = {
				body = contents :: string,
				contentType = TYPES[(extension or ""):lower()] or "application/octet-stream",
			}
		end
	end
	local count = 0
	for _ in cache do
		count += 1
	end
	Log.info(`static: cached {count} file(s) from {root}`)
end

--[[
	Serve /static/<name>.

	Only the bare filename is honoured -- any path containing a separator or a
	parent reference is refused outright rather than normalized, since there
	are no subdirectories to reach legitimately and normalizing is where
	traversal bugs live.
]]
function Static.serve(name: string): Response.T?
	if name:find("[/\\]") or name:find("%.%.") then
		return nil
	end
	local file = cache[name]
	if file == nil then
		return nil
	end
	local response = Response.text(file.body)
	response.headers["content-type"] = file.contentType
	-- These are versioned by hand; a short cache spares a reload the refetch
	-- without pinning a stale stylesheet for long.
	response.headers["cache-control"] = "public, max-age=300"
	return response
end

return Static
