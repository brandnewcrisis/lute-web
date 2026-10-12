--!strict
--[[
	Response construction.

	Every response carries the same hardening headers. The CSP is strict
	(`default-src 'self'`): no inline scripts, no inline styles, nothing from
	another origin. Live pages fit inside it, since their script is one file
	served from here and their socket goes back to the same host.

	Note the single-cookie constraint: Lute models response headers as a
	string map, so a response can carry at most one Set-Cookie. Keep anything
	else you would have put in a cookie inside the session payload.
]]
local Html = require("@web/html")
local Json = require("@web/json")

local Response = {}

export type T = {
	status: number,
	body: string,
	headers: { [string]: string },
}

--[[
	Headers added to every response.

	Secure by default, and deliberately strict. Call `configure` to loosen
	it, for instance to allow images from a CDN.
]]
local SECURITY_HEADERS: { [string]: string } = {
	["content-security-policy"] = "default-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
	["x-content-type-options"] = "nosniff",
	["x-frame-options"] = "DENY",
	["referrer-policy"] = "no-referrer",
	-- no-store rather than no-cache: an app behind a login should not leave
	-- responses in an intermediary or replay a stale one from the back button.
	["cache-control"] = "no-store",
}

--[[
	Replace or extend the default headers.

	    Response.configure({ ["content-security-policy"] = "... img-src https://cdn ..." })

	Passing false for a name removes it entirely.
]]
function Response.configure(headers: { [string]: string | boolean })
	for name, value in headers do
		if value == false then
			SECURITY_HEADERS[name:lower()] = nil
		elseif type(value) == "string" then
			SECURITY_HEADERS[name:lower()] = value
		end
	end
end

local function base(status: number, body: string, contentType: string): T
	local headers: { [string]: string } = { ["content-type"] = contentType }
	for name, value in SECURITY_HEADERS do
		headers[name] = value
	end
	return { status = status, body = body, headers = headers }
end

-- An HTML response from a node, a list of nodes, or markup already rendered.
function Response.html(content: any, status: number?): T
	local markup = if type(content) == "string" then content else Html.render(content)
	return base(status or 200, markup, "text/html; charset=utf-8")
end

function Response.text(body: string, status: number?): T
	return base(status or 200, body, "text/plain; charset=utf-8")
end

function Response.json(value: any, status: number?): T
	return base(status or 200, Json.encode(value), "application/json; charset=utf-8")
end

function Response.redirect(location: string, status: number?): T
	local response = base(status or 303, "", "text/plain; charset=utf-8")
	response.headers["location"] = location
	return response
end

function Response.withCookie(response: T, cookie: string): T
	response.headers["set-cookie"] = cookie
	return response
end

function Response.withHeader(response: T, name: string, value: string): T
	response.headers[name:lower()] = value
	return response
end

-- True for a table shaped like a response, as opposed to a node. Lets a
-- page function answer with a redirect or a 404 instead of markup.
function Response.is(value: any): boolean
	return type(value) == "table"
		and not Html.isNode(value)
		and type(value.status) == "number"
		and type(value.headers) == "table"
end

return Response
