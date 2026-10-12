--!strict
-- Cookie parsing and serialization.
local Cookies = {}

-- Parse a request Cookie header into a name -> value map.
function Cookies.parse(header: string?): { [string]: string }
	local out: { [string]: string } = {}
	if header == nil then
		return out
	end
	for pair in header:gmatch("[^;]+") do
		local name, value = pair:match("^%s*([^=%s]+)%s*=%s*(.*)%s*$")
		if name then
			out[name] = (value:gsub("%s+$", ""))
		end
	end
	return out
end

export type Options = {
	maxAge: number?,
	secure: boolean?,
	path: string?,
	sameSite: string?,
}

--[[
	Build a Set-Cookie value.

	HttpOnly always: no view has any reason to read the session from script,
	and it takes the cookie out of reach of an XSS that slips past the escaping
	layer. SameSite=Lax rather than Strict because the OAuth provider redirects
	back into the panel by GET, and Strict would drop the cookie on that hop
	and bounce the user straight back to the login page.
]]
function Cookies.serialize(name: string, value: string, options: Options?): string
	local opts = options or {}
	local parts = { `{name}={value}` }
	table.insert(parts, "Path=" .. (opts.path or "/"))
	table.insert(parts, "HttpOnly")
	table.insert(parts, "SameSite=" .. (opts.sameSite or "Lax"))
	if opts.secure then
		table.insert(parts, "Secure")
	end
	if opts.maxAge then
		table.insert(parts, `Max-Age={math.floor(opts.maxAge)}`)
	end
	return table.concat(parts, "; ")
end

function Cookies.expire(name: string): string
	return `{name}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0`
end

return Cookies
