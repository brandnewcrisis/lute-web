--!strict
-- Copies client/live.js into src/client.luau, so the library can serve its
-- browser half without knowing where on disk it was installed.
--   lute run tools/embed.luau
local fs = require("@lute/fs")

local function read(path: string): string
	local handle = fs.open(path, "r")
	local text = fs.read(handle)
	fs.close(handle)
	return text
end

local source = read("./client/live.js")

-- Pick a long-bracket level the script does not contain.
local level = 1
while source:find("]" .. string.rep("=", level) .. "]", 1, true) do
	level += 1
end
local eq = string.rep("=", level)

-- A cheap content hash, used only to bust the browser cache when the
-- script changes.
local hash = 5381
for index = 1, #source do
	hash = (hash * 33 + source:byte(index)) % 4294967296
end

local out = table.concat({
	"--!strict",
	"-- GENERATED from client/live.js by tools/embed.luau. Do not edit.",
	"return {",
	`\tversion = "{string.format("%08x", hash)}",`,
	`\tsource = [{eq}[`,
	source .. `]{eq}],`,
	"}",
	"",
}, "\n")

local handle = fs.open("./src/client.luau", "w")
fs.write(handle, out)
fs.close(handle)
print(`wrote src/client.luau ({#source} bytes, version {string.format("%08x", hash)})`)
