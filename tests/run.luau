--!strict
-- Runs every *.test.luau in tests/. `lute run tests/run.luau`
local fs = require("@lute/fs")
local process = require("@lute/process")

local names = {}
for _, entry in fs.listdir("./tests") do
	local name = (entry :: any).name or tostring(entry)
	if name:match("%.test%.luau$") then
		table.insert(names, name)
	end
end
table.sort(names)

local failedSuites = {}
for _, name in names do
	print(`\n=== {name} ===`)
	local result = process.run({ process.execPath(), "run", `./tests/{name}` })
	print((result.stdout:gsub("\n$", "")))
	if result.stderr ~= "" then
		print(result.stderr)
	end
	if not result.ok or result.stdout:find("FAILURES") then
		table.insert(failedSuites, name)
	end
end

print("\n" .. string.rep("-", 46))
if #failedSuites == 0 then
	print("ALL " .. #names .. " SUITES PASS")
else
	print(`FAILED: {table.concat(failedSuites, ", ")}`)
	process.exit(1)
end
