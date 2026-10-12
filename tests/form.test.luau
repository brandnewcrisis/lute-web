local Form = require("@web/form")
local fails = 0
local function check(n, c, got) if not c then fails += 1; print("FAIL " .. n .. (if got ~= nil then "  got: " .. tostring(got) else "")) else print("ok   " .. n) end end

check("simple", Form.parse("a=1&b=2").a == "1")
check("plus is space", Form.parse("q=hello+world").q == "hello world")
check("percent decode", Form.parse("q=a%20b%26c").q == "a b&c")
check("empty value", Form.parse("a=&b=2").a == "")
check("no equals", Form.parse("flag").flag == "")
check("empty body", next(Form.parse("")) == nil)
check("last wins", Form.parse("a=1&a=2").a == "2")
check("multi keeps both", #Form.parseMulti("a=1&a=2").a == 2)
check("decodes key too", Form.parse("my%20key=v")["my key"] == "v")
check("utf8", Form.parse("n=h%C3%A9llo").n == "héllo")
-- a value containing = must survive (base64, JWTs)
check("value with equals", Form.parse("t=abc==").t == "abc==")
check("encode roundtrip", Form.parse(Form.encode({ a = "x y", b = "p&q" })).b == "p&q")
check("encode is sorted", Form.encode({ b = "2", a = "1" }) == "a=1&b=2")
check("encodeComponent", Form.encodeComponent("a b&c") == "a%20b%26c")

print(if fails == 0 then "\nALL PASS" else "\n" .. fails .. " FAILURES")
