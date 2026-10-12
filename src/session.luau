--!strict
--[[
	Stateless sessions in a sealed cookie.

	The payload is JSON, encrypted and authenticated with the panel's
	secretbox key, so the cookie is both unreadable and untamperable by the
	client. Keeping it stateless means a panel restart does not sign everyone
	out mid-incident, which matters when the panel is the thing you reach for
	when something is wrong.

	The CSRF token lives in the payload rather than a second cookie, because
	Lute allows only one Set-Cookie per response.
]]
local crypto = require("@lute/crypto")
local Bytes = require("@web/bytes")
local Json = require("@web/json")

local Session = {}

Session.COOKIE_NAME = "sb_panel"

export type Data = {
	userId: number,      -- Roblox user id
	name: string,        -- Roblox username at sign-in
	displayName: string,
	issuedAt: number,
	expiresAt: number,
	csrf: string,
}

local function keyBuffer(secret: string): buffer
	-- The configured key is hex or base64url text; hashing it to exactly 32
	-- bytes accepts either form and any length without a separate decode path.
	return crypto.digest(crypto.hash.sha256, secret)
end

--[[
	Seal a session into cookie text.

	Format is `nonce.ciphertext`, both base64url. The nonce is generated per
	seal by the secretbox and must travel with the message for `open` to
	reconstruct the box.
]]
function Session.seal(secret: string, data: Data): string
	local box = crypto.secretbox.seal(Json.encode(data), keyBuffer(secret))
	return Bytes.toBase64Url(box.nonce) .. "." .. Bytes.toBase64Url(box.ciphertext)
end

-- Returns nil for anything not currently valid: malformed, forged, or expired.
function Session.open(secret: string, cookie: string?): Data?
	if cookie == nil then
		return nil
	end
	local noncePart, cipherPart = cookie:match("^([^.]+)%.([^.]+)$")
	if noncePart == nil or cipherPart == nil then
		return nil
	end
	local nonce = Bytes.fromBase64Url(noncePart)
	local ciphertext = Bytes.fromBase64Url(cipherPart)
	if nonce == nil or ciphertext == nil then
		return nil
	end
	-- A forged or tampered cookie fails authentication inside `open`, which
	-- raises; that is an expected outcome here, not an error worth logging.
	local ok, plaintext = pcall(crypto.secretbox.open, {
		nonce = nonce :: buffer,
		ciphertext = ciphertext :: buffer,
		key = keyBuffer(secret),
	})
	if not ok then
		return nil
	end
	local decoded = Json.decode(buffer.tostring(plaintext :: buffer))
	if type(decoded) ~= "table" then
		return nil
	end
	local data = decoded :: Data
	if type(data.userId) ~= "number" or type(data.expiresAt) ~= "number" then
		return nil
	end
	if os.time() >= data.expiresAt then
		return nil
	end
	return data
end

function Session.create(userId: number, name: string, displayName: string, lifetimeSeconds: number): Data
	local now = os.time()
	return {
		userId = userId,
		name = name,
		displayName = displayName,
		issuedAt = now,
		expiresAt = now + lifetimeSeconds,
		csrf = Bytes.token(24),
	}
end

return Session
