--!strict
--[[
	The glue: an app you can mount routes on and serve.

	Lute's server hands you a request and takes a response, and everything
	between -- routing, 404s, an error that would otherwise drop the
	connection, header casing -- is left to you. This is that middle, written
	once.
]]
local server = require("@lute/net/server")
local Router = require("@web/router")
local Response = require("@web/response")
local Static = require("@web/static")
local Log = require("@web/log")

local App = {}

export type Options = {
	host: string?,
	port: number?,
	staticDir: string?,
	staticPrefix: string?,
	-- Runs before every route. Return a response to short-circuit (auth
	-- failures, rate limits); return nil to continue.
	before: ((Router.Request) -> Response.T?)?,
	onError: ((Router.Request, any) -> Response.T)?,
}

function App.new(options: Options?)
	local opts = options or {}
	local router = Router.new()
	local self = {}
	self.router = router

	self.get = router.get
	self.post = router.post
	self.delete = router.delete
	self.add = router.add

	local staticPrefix = opts.staticPrefix or "static"
	if opts.staticDir then
		Static.load(opts.staticDir)
		router.get(`/{staticPrefix}/:name`, function(request: Router.Request): Response.T
			return Static.serve(request.params.name) or Response.text("not found", 404)
		end)
	end

	-- Header names arrive in whatever case the client used; lowercasing once
	-- here means every lookup downstream can assume one form.
	local function normalize(headers: { [string]: string }): { [string]: string }
		local out: { [string]: string } = {}
		for name, value in headers do
			out[name:lower()] = value
		end
		return out
	end

	function self.handle(raw: server.ReceivedRequest): Response.T
		local request: Router.Request = {
			method = raw.method,
			-- Lute may hand back the query string attached to the path; the
			-- router matches on path alone.
			path = (raw.path:match("^([^?]*)") :: string),
			body = raw.body,
			query = raw.query,
			headers = normalize(raw.headers),
			params = {},
		}

		local handler, params, pathMatched = router.resolve(request.method, request.path)
		if handler == nil then
			-- 405 rather than 404 when the path exists under another verb:
			-- a wrong-method 404 sends people hunting for a typo in the URL.
			return if pathMatched
				then Response.text("method not allowed", 405)
				else Response.text("not found", 404)
		end
		request.params = params

		if opts.before then
			local short = opts.before(request)
			if short ~= nil then
				return short
			end
		end
		return handler(request)
	end

	function self.serve()
		local host = opts.host or "127.0.0.1"
		local port = opts.port or 8080
		local instance = server.serve({
			hostname = host,
			port = port,
			handler = function(raw)
				-- A raising handler would otherwise drop the connection with
				-- no status and no log line, which is the worst possible way
				-- to find out about a bug.
				local ok, result = pcall(self.handle, raw)
				if ok then
					return result
				end
				Log.error(`unhandled error on {raw.method} {raw.path}: {result}`)
				if opts.onError then
					local handled, custom = pcall(opts.onError, {
						method = raw.method, path = raw.path, body = raw.body,
						query = raw.query, headers = normalize(raw.headers), params = {},
					} :: any, result)
					if handled then
						return custom
					end
				end
				return Response.text("internal error", 500)
			end,
		})
		Log.info(`listening on http://{instance.hostname}:{instance.port}`)
		return instance
	end

	return self
end

return App
