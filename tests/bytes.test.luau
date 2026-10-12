local Bytes = require("@web/bytes")

local function bufOf(s: string): buffer
	local b = buffer.create(#s)
	buffer.writestring(b, 0, s)
	return b
end

local fails = 0
local function check(name, cond)
	if not cond then fails += 1; print("FAIL " .. name) else print("ok   " .. name) end
end

-- hex
check("hex empty", Bytes.toHex(bufOf("")) == "")
check("hex abc", Bytes.toHex(bufOf("abc")) == "616263")
check("hex roundtrip", buffer.tostring(Bytes.fromHex("616263") :: buffer) == "abc")
check("hex reject odd", Bytes.fromHex("abc") == nil)
check("hex reject nonhex", Bytes.fromHex("zz") == nil)

-- base64url vectors (RFC 4648 unpadded)
local vectors = {
	{ "", "" }, { "f", "Zg" }, { "fo", "Zm8" }, { "foo", "Zm9v" },
	{ "foob", "Zm9vYg" }, { "fooba", "Zm9vYmE" }, { "foobar", "Zm9vYmFy" },
}
for _, v in vectors do
	local enc = Bytes.toBase64Url(bufOf(v[1]))
	check("b64 enc '" .. v[1] .. "' -> " .. enc, enc == v[2])
	local dec = Bytes.fromBase64Url(v[2])
	check("b64 dec '" .. v[2] .. "'", dec ~= nil and buffer.tostring(dec :: buffer) == v[1])
end

-- binary roundtrip across all byte values
local all = buffer.create(256)
for i = 0, 255 do buffer.writeu8(all, i, i) end
local rt = Bytes.fromBase64Url(Bytes.toBase64Url(all))
check("b64 all-bytes roundtrip", rt ~= nil and buffer.tostring(rt :: buffer) == buffer.tostring(all))
check("b64 url-safe chars", Bytes.toBase64Url(all):match("[+/=]") == nil)
check("b64 reject bad char", Bytes.fromBase64Url("Zm9v!") == nil)
check("b64 reject len%4==1", Bytes.fromBase64Url("Zm9vY") == nil)

-- random
check("random len", buffer.len(Bytes.random(100)) == 100)
check("random differs", buffer.tostring(Bytes.random(64)) ~= buffer.tostring(Bytes.random(64)))
check("token urlsafe", Bytes.token():match("^[A-Za-z0-9_-]+$") ~= nil)

-- equals
check("eq same", Bytes.equals("hello", "hello"))
check("eq diff", not Bytes.equals("hello", "hellp"))
check("eq len", not Bytes.equals("hello", "hello2"))
check("eq empty", Bytes.equals("", ""))

print(if fails == 0 then "\nALL PASS" else "\n" .. fails .. " FAILURES")
