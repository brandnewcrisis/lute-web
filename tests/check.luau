-- Shared by the suites: a few assertions and the summary line that
-- tests/run.luau looks for.
local Check = {}

local fails = 0

function Check.check(name: string, condition: any, got: any?)
	if condition then
		print("ok   " .. name)
	else
		fails += 1
		print("FAIL " .. name .. (if got ~= nil then "  got: " .. tostring(got) else ""))
	end
end

function Check.eq(name: string, got: any, want: any)
	if got == want then
		print("ok   " .. name)
	else
		fails += 1
		print(`FAIL {name}\n       got:  {tostring(got)}\n       want: {tostring(want)}`)
	end
end

-- Passes when `fn` raises, and, if `pattern` is given, the message contains it.
function Check.raises(name: string, fn: () -> (), pattern: string?)
	local ok, err = pcall(fn)
	if ok then
		fails += 1
		print("FAIL " .. name .. "  (did not raise)")
	elseif pattern and not tostring(err):find(pattern, 1, true) then
		fails += 1
		print(`FAIL {name}  raised: {tostring(err)}`)
	else
		print("ok   " .. name)
	end
end

function Check.done()
	print(if fails == 0 then "\nALL PASS" else "\n" .. fails .. " FAILURES")
end

return Check
