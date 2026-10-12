local Json = require("@web/json")
local fails = 0
local function check(n, c) if not c then fails += 1; print("FAIL " .. n) else print("ok   " .. n) end end

local obj = Json.decodeObject('{"a":1,"b":"x"}')
local keys = {}
for k in obj do table.insert(keys, k) end
check("only real keys survive decode", #keys == 2)
check("keys are sortable", (pcall(table.sort, keys)))
check("nested object clean", (function()
	local o = Json.decodeObject('{"outer":{"inner":{"deep":1}}}')
	local n = 0
	for _ in o.outer.inner do n += 1 end
	return n == 1
end)())
check("array decodes", (function()
	local o = Json.decodeObject('{"xs":[1,2,3]}')
	return #o.xs == 3
end)())
check("null becomes nil", (function()
	local o = Json.decodeObject('{"a":null,"b":2}')
	return o.a == nil and o.b == 2
end)())
check("bad json returns error", (Json.decode("{nope") == nil))
check("empty body returns error", (Json.decode("") == nil))
check("non-object rejected", (Json.decodeObject("42") == nil))
check("encode roundtrip", Json.decodeObject(Json.encode({ q = "he said \"hi\"" })).q == 'he said "hi"')
print(if fails == 0 then "\nALL PASS" else "\n" .. fails .. " FAILURES")
