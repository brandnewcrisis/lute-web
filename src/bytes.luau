--!strict
--[[
	Encoding and randomness primitives.

	Lute's crypto library gives us SHA-2 and a secretbox but no hex, no base64
	and no random-bytes call, so those are built here on top of what it does
	expose. `random` leans on `secretbox.keygen()`, which returns 32 fresh
	CSPRNG bytes every call -- it is advertised as a key generator, but a key
	generator that repeated itself would be broken, so it is exactly the
	entropy source we want for session ids, CSRF tokens and PKCE verifiers.
]]
local crypto = require("@lute/crypto")

local Bytes = {}

local HEX = "0123456789abcdef"

function Bytes.toHex(buf: buffer): string
	local out = table.create(buffer.len(buf))
	for i = 0, buffer.len(buf) - 1 do
		local byte = buffer.readu8(buf, i)
		local hi = bit32.rshift(byte, 4) + 1
		local lo = bit32.band(byte, 15) + 1
		out[i + 1] = HEX:sub(hi, hi) .. HEX:sub(lo, lo)
	end
	return table.concat(out)
end

function Bytes.fromHex(hex: string): buffer?
	if #hex % 2 ~= 0 or hex:match("^%x*$") == nil then
		return nil
	end
	local buf = buffer.create(#hex // 2)
	for i = 1, #hex, 2 do
		buffer.writeu8(buf, (i - 1) // 2, tonumber(hex:sub(i, i + 1), 16) :: number)
	end
	return buf
end

-- RFC 4648 base64url, no padding: safe in cookies, headers and query strings
-- without a further round of percent-encoding.
local B64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

function Bytes.toBase64Url(buf: buffer): string
	local out = {}
	local len = buffer.len(buf)
	local i = 0
	while i < len do
		local remaining = len - i
		local b1 = buffer.readu8(buf, i)
		local b2 = if remaining > 1 then buffer.readu8(buf, i + 1) else 0
		local b3 = if remaining > 2 then buffer.readu8(buf, i + 2) else 0
		local n = bit32.bor(bit32.lshift(b1, 16), bit32.lshift(b2, 8), b3)
		local c1 = bit32.band(bit32.rshift(n, 18), 63) + 1
		local c2 = bit32.band(bit32.rshift(n, 12), 63) + 1
		local c3 = bit32.band(bit32.rshift(n, 6), 63) + 1
		local c4 = bit32.band(n, 63) + 1
		table.insert(out, B64URL:sub(c1, c1) .. B64URL:sub(c2, c2))
		if remaining > 1 then
			table.insert(out, B64URL:sub(c3, c3))
		end
		if remaining > 2 then
			table.insert(out, B64URL:sub(c4, c4))
		end
		i += 3
	end
	return table.concat(out)
end

local B64URL_INV: { [string]: number } = {}
for index = 1, #B64URL do
	B64URL_INV[B64URL:sub(index, index)] = index - 1
end

function Bytes.fromBase64Url(text: string): buffer?
	local values = table.create(#text)
	for index = 1, #text do
		local value = B64URL_INV[text:sub(index, index)]
		if value == nil then
			return nil
		end
		values[index] = value
	end
	local count = #values
	-- 4 chars -> 3 bytes; a trailing group of 1 char cannot encode anything.
	if count % 4 == 1 then
		return nil
	end
	local outLen = (count // 4) * 3 + ({ [0] = 0, 0, 1, 2 })[count % 4]
	local buf = buffer.create(outLen)
	local pos = 0
	local i = 1
	while i <= count do
		local remaining = count - i + 1
		local v1, v2 = values[i], values[i + 1] or 0
		local v3, v4 = values[i + 2] or 0, values[i + 3] or 0
		local n = bit32.bor(bit32.lshift(v1, 18), bit32.lshift(v2, 12), bit32.lshift(v3, 6), v4)
		buffer.writeu8(buf, pos, bit32.band(bit32.rshift(n, 16), 255))
		if remaining > 2 then
			buffer.writeu8(buf, pos + 1, bit32.band(bit32.rshift(n, 8), 255))
		end
		if remaining > 3 then
			buffer.writeu8(buf, pos + 2, bit32.band(n, 255))
		end
		pos += 3
		i += 4
	end
	return buf
end

-- `count` cryptographically random bytes. keygen() yields 32 at a time, so
-- longer requests are stitched from several draws.
function Bytes.random(count: number): buffer
	local out = buffer.create(count)
	local written = 0
	while written < count do
		local chunk = crypto.secretbox.keygen()
		local take = math.min(32, count - written)
		buffer.copy(out, written, chunk, 0, take)
		written += take
	end
	return out
end

-- A URL-safe random token. 32 bytes is 256 bits: far past guessing.
function Bytes.token(byteCount: number?): string
	return Bytes.toBase64Url(Bytes.random(byteCount or 32))
end

--[[
	Compare two strings without leaking where they first differ.

	Session ids, CSRF tokens and ingest signatures are all compared against
	attacker-supplied input. A plain `==` on strings can return early on the
	first differing byte, which over many tries reveals the secret a byte at a
	time. Folding every byte into an accumulator makes the work independent of
	the data.
]]
function Bytes.equals(a: string, b: string): boolean
	-- Lengths are not secret (they are fixed by format), but differing lengths
	-- must still not short-circuit the loop below, so fold length in instead.
	local diff = bit32.bxor(#a, #b)
	local len = math.min(#a, #b)
	for index = 1, len do
		diff = bit32.bor(diff, bit32.bxor(a:byte(index) :: number, b:byte(index) :: number))
	end
	return diff == 0
end

return Bytes
