--!strict
--[[
	Response construction.

	Every response carries the same hardening headers. The CSP is strict
	(`default-src 'self'`) and the panel is built to live inside it: htmx is
	served from ./public rather than a CDN, and there are no inline scripts or
	styles anywhere in the views.

	Note the single-cookie constraint: Lute models response headers as a
	string map, so a response can carry at most one Set-Cookie. That is why the
	CSRF token travels inside the session payload instead of a cookie of its
	own.
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

	Secure by default, and deliberately strict: a CSP of `default-src 'self'`
	means inline scripts and styles do not run. htmx needs neither -- it is a
	file you serve and a set of attributes -- so an htmx app can live inside
	this policy where a typical SPA cannot. Call `configure` to loosen it.
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

function Response.html(node: Html.Node | string, status: number?): T
	local markup = if type(node) == "string" then node else Html.render(node :: Html.Node)
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

-- htmx honours this by navigating the whole page, which is what we want after
-- a session expires mid-action rather than swapping a login form into a table.
function Response.hxRedirect(location: string): T
	local response = base(200, "", "text/plain; charset=utf-8")
	response.headers["hx-redirect"] = location
	return response
end

return Response
