--!strict
--[[
	Method + path routing with named parameters.

	Patterns look like "/servers/:jobId/players". A segment beginning with ":"
	captures that segment into `params`. Matching is exact on segment count, so
	"/servers/:id" never swallows "/servers/a/b".
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
	-- filled in by the auth layer once the session is resolved
	actor: any?,
}

export type Handler = (Request) -> Response.T

type Route = {
	method: string,
	segments: { string },
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
		table.insert(routes, {
			method = method:upper(),
			segments = split(pattern),
			handler = handler,
		})
	end

	function self.get(pattern: string, handler: Handler) self.add("GET", pattern, handler) end
	function self.post(pattern: string, handler: Handler) self.add("POST", pattern, handler) end
	function self.delete(pattern: string, handler: Handler) self.add("DELETE", pattern, handler) end

	--[[
		Resolve a request to a handler.

		Tracks whether any route matched the path but not the method, so a
		wrong verb answers 405 rather than a misleading 404.
	]]
	function self.resolve(method: string, path: string): (Handler?, { [string]: string }, boolean)
		local wanted = split(path)
		local pathMatched = false
		for _, route in routes do
			if #route.segments ~= #wanted then
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
			if matched then
				pathMatched = true
				if route.method == method:upper() then
					return route.handler, params, true
				end
			end
		end
		return nil, {}, pathMatched
	end

	return self
end

return Router
