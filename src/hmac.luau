--!strict
--[[
	HMAC-SHA256 (RFC 2104), built on Lute's `crypto.digest`.

	Lute exposes raw hashes but no keyed MAC, and a raw hash is not a
	substitute: `sha256(secret .. body)` is forgeable by length extension.
	The ingest endpoint authenticates every heartbeat from a game server with
	this, so it has to be the real construction. Verified against RFC 4231.
]]
local crypto = require("@lute/crypto")
local Bytes = require("@web/bytes")

local Hmac = {}

local BLOCK_SIZE = 64 -- SHA-256 operates on 512-bit blocks

local function sha256(message: string): string
	return buffer.tostring(crypto.digest(crypto.hash.sha256, message))
end

local function xorPad(key: string, pad: number): string
	local out = table.create(BLOCK_SIZE)
	for index = 1, BLOCK_SIZE do
		local byte = if index <= #key then key:byte(index) :: number else 0
		out[index] = string.char(bit32.bxor(byte, pad))
	end
	return table.concat(out)
end

-- Raw 32-byte MAC as a binary string.
function Hmac.raw(key: string, message: string): string
	-- Keys longer than one block are hashed down first; shorter ones are
	-- zero-padded, which xorPad does implicitly.
	local normalized = if #key > BLOCK_SIZE then sha256(key) else key
	local inner = sha256(xorPad(normalized, 0x36) .. message)
	return sha256(xorPad(normalized, 0x5c) .. inner)
end

-- Lowercase hex MAC, the form carried in the X-Starbreak-Signature header.
function Hmac.hex(key: string, message: string): string
	local raw = Hmac.raw(key, message)
	local buf = buffer.create(#raw)
	buffer.writestring(buf, 0, raw)
	return Bytes.toHex(buf)
end

-- Constant-time check of an untrusted hex signature.
function Hmac.verify(key: string, message: string, signatureHex: string): boolean
	return Bytes.equals(Hmac.hex(key, message), signatureHex:lower())
end

return Hmac
