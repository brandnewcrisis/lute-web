local Hmac = require("@web/hmac")

local fails = 0
local function check(name, cond)
	if not cond then fails += 1; print("FAIL " .. name) else print("ok   " .. name) end
end

-- RFC 4231 test vectors for HMAC-SHA256
local case1Key = string.rep(string.char(0x0b), 20)
check("RFC4231 #1", Hmac.hex(case1Key, "Hi There")
	== "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")

check("RFC4231 #2", Hmac.hex("Jefe", "what do ya want for nothing?")
	== "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")

check("RFC4231 #3", Hmac.hex(string.rep(string.char(0xaa), 20), string.rep(string.char(0xdd), 50))
	== "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe")

-- #6: key longer than one block (131 bytes) exercises the hash-down path
check("RFC4231 #6 (long key)", Hmac.hex(string.rep(string.char(0xaa), 131),
	"Test Using Larger Than Block-Size Key - Hash Key First")
	== "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")

check("verify accepts", Hmac.verify("k", "msg", Hmac.hex("k", "msg")))
check("verify accepts uppercase", Hmac.verify("k", "msg", Hmac.hex("k", "msg"):upper()))
check("verify rejects wrong key", not Hmac.verify("k2", "msg", Hmac.hex("k", "msg")))
check("verify rejects tampered body", not Hmac.verify("k", "msg!", Hmac.hex("k", "msg")))
check("verify rejects garbage", not Hmac.verify("k", "msg", "deadbeef"))

print(if fails == 0 then "\nALL PASS" else "\n" .. fails .. " FAILURES")
