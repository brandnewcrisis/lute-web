--!strict
--[[
	Method + path routing with named parameters.

	Patterns look like "/servers/:jobId/players". A segment beginning with ":"
	captures that segment into `params`. Matching is exact on segment count, so
	"/servers/:id" never swallows "/servers/a/b".

	A final "*" segment matches whatever is left, including nothing: "/app/*"
	takes "/app" and everything under it, and the remainder is `params["*"]`.
	A route without a wildcard always wins over one with, whichever was added
	first, so a catch-all page cannot shadow "/login" or the static files.
]]
local Response = require("@web/response")

local Router = {}

export type Request = {
	method: string,
	path: string,
	body: string,
	query: { [string]: string },
	headers: { [string]: string },
	params: { [string]: string },
	-- Yours to fill in from a `before` hook: the signed-in user, usually.
	actor: any?,
}

export type Handler = (Request) -> Response.T

type Route = {
	method: string,
	segments: { string },
	wildcard: boolean,
	handler: Handler,
}

local function split(path: string): { string }
	local segments = {}
	for segment in path:gmatch("[^/]+") do
		table.insert(segments, segment)
	end
	return segments
end

function Router.new()
	local routes: { Route } = {}
	local self = {}

	function self.add(method: string, pattern: string, handler: Handler)
		local segments = split(pattern)
		local wildcard = segments[#segments] == "*"
		if wildcard then
			table.remove(segments)
		end
		table.insert(routes, {
			method = method:upper(),
			segments = segments,
			wildcard = wildcard,
			handler = handler,
		})
	end

	function self.get(pattern: string, handler: Handler) self.add("GET", pattern, handler) end
	function self.post(pattern: string, handler: Handler) self.add("POST", pattern, handler) end
	function self.put(pattern: string, handler: Handler) self.add("PUT", pattern, handler) end
	function self.patch(pattern: string, handler: Handler) self.add("PATCH", pattern, handler) end
	function self.delete(pattern: string, handler: Handler) self.add("DELETE", pattern, handler) end

	--[[
		Resolve a request to a handler.

		Tracks whether any route matched the path but not the method, so a
		wrong verb answers 405 rather than a misleading 404.
	]]
	function self.resolve(method: string, path: string): (Handler?, { [string]: string }, boolean)
		local wanted = split(path)
		local verb = method:upper()
		local pathMatched = false
		-- The best wildcard seen so far: the one with the longest fixed part.
		local fallback: Route? = nil
		local fallbackParams: { [string]: string } = {}

		for _, route in routes do
			if route.wildcard then
				if #wanted < #route.segments then
					continue
				end
			elseif #route.segments ~= #wanted then
				continue
			end
			local params: { [string]: string } = {}
			local matched = true
			for index, segment in route.segments do
				if segment:sub(1, 1) == ":" then
					params[segment:sub(2)] = wanted[index]
				elseif segment ~= wanted[index] then
					matched = false
					break
				end
			end
			if not matched then
				continue
			end
			pathMatched = true
			if route.method ~= verb then
				continue
			end
			if not route.wildcard then
				return route.handler, params, true
			end
			if fallback == nil or #route.segments > #fallback.segments then
				params["*"] = table.concat(wanted, "/", #route.segments + 1)
				fallback, fallbackParams = route, params
			end
		end

		if fallback then
			return fallback.handler, fallbackParams, true
		end
		return nil, {}, pathMatched
	end

	return self
end

return Router
