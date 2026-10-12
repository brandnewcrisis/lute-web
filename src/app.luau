--!strict
--[[
	An app: routes, pages, and the server that carries them.

	    local app = web.app({ port = 8080, staticDir = "./public" })
	    app.page("/", Home)                -- a live page
	    app.post("/login", signIn)         -- a plain request/response route
	    app.serve()

	`page` is the new thing. Its function is a component: it returns
	elements, and whatever in them was written as a function stays connected
	to this server for as long as the tab is open. `get`, `post` and the rest
	are ordinary handlers that return a response, for the jobs a live page
	cannot do: setting a cookie, serving JSON, receiving a webhook.
]]
local server = require("@lute/net/server")
local Router = require("@web/router")
local Response = require("@web/response")
local Static = require("@web/static")
local Log = require("@web/log")
local Html = require("@web/html")
local Live = require("@web/live")
local Graph = require("@web/graph")
local Client = require("@web/client")

local App = {}

export type Options = {
	host: string?,
	port: number?,
	staticDir: string?,
	staticPrefix: string?,
	-- Runs before every route and page. Return a response to short-circuit
	-- (not signed in, rate limited); return nil to continue.
	before: ((Router.Request) -> Response.T?)?,
	onError: ((Router.Request, any) -> Response.T)?,
	-- Where the live client script and socket are served from.
	livePrefix: string?,
	-- Send the text of a failed event handler's error to the browser
	-- console. For development; leave it off where visitors are strangers.
	debug: boolean?,
}

export type PageOptions = {
	-- Keep the page connected even if nothing in it is reactive. For a page
	-- that only uses `every` with `navigate` or `emit`.
	live: boolean?,
}

export type Request = Router.Request
export type Component = (Router.Request) -> any

local create = Html.create

-- Find the first child element with this tag.
local function childTag(node: any, tag: string): (any?, number?)
	for index, child in node.children do
		if type(child) == "table" and child.kind == "el" and child.tag == tag then
			return child, index
		end
	end
	return nil, nil
end

-- A shallow copy with its own children list. The nodes a page returns may
-- be shared (a layout built once at module level), so adding the client
-- script must not write into them.
local function copyNode(node: any): any
	local copy = table.clone(node)
	copy.children = table.clone(node.children)
	return setmetatable(copy, getmetatable(node))
end

--[[
	Make whatever a page returned into a whole document.

	A page that returns <html> is used as it is. Anything else is treated as
	the body and given the smallest shell a browser will render properly.
]]
local function documentOf(content: any): any
	if Html.isNode(content) and content.kind == "el" and content.tag == "html" then
		return content
	end
	return create "html" {
		lang = "en",
		create "head" {
			create "meta" { charset = "utf-8" },
			create "meta" { name = "viewport", content = "width=device-width, initial-scale=1" },
		},
		create "body" { content },
	}
end

local function withScript(document: any, script: any): any
	local copy = copyNode(document)
	local head, index = childTag(copy, "head")
	if head and index then
		local newHead = copyNode(head)
		table.insert(newHead.children, script)
		copy.children[index] = newHead
	else
		local fresh: any = create("head", { script })
		table.insert(copy.children, 1, fresh)
	end
	return copy
end

function App.new(options: Options?)
	local opts: Options = options or {}
	local router = Router.new()
	local self = {}
	self.router = router

	self.get = router.get
	self.post = router.post
	self.put = router.put
	self.patch = router.patch
	self.delete = router.delete
	self.add = router.add

	local livePrefix = opts.livePrefix or "/_live"
	local socketPath = livePrefix .. "/ws"
	local clientPath = `{livePrefix}/client.js`

	local staticPrefix = opts.staticPrefix or "static"
	if opts.staticDir then
		Static.load(opts.staticDir)
		router.get(`/{staticPrefix}/:name`, function(request: Router.Request): Response.T
			return Static.serve(request.params.name) or Response.text("not found", 404)
		end)
	end

	router.get(clientPath, function(): Response.T
		local response = Response.text(Client.source)
		response.headers["content-type"] = "text/javascript; charset=utf-8"
		-- The URL carries a hash of the script, so it can be kept for good.
		response.headers["cache-control"] = "public, max-age=31536000, immutable"
		return response
	end)

	--[[
		Mount a component at a path.

		The component is called with the request, inside a scope of its own,
		and may wait on I/O before returning. It returns elements, or a
		response when the answer is not a page: a redirect to the login, a
		404. If nothing it returned is reactive the page is sent as plain
		HTML with no script and nothing is kept for it.
	]]
	function self.page(pattern: string, component: Component, pageOptions: PageOptions?)
		local forceLive = pageOptions ~= nil and pageOptions.live == true
		local handler: Router.Handler
		handler = function(request: Router.Request): Response.T
			local mount = Live.mount(function()
				return component(request)
			end, { path = request.path, query = request.query, url = request.path })
			-- A URL can be moved to in place when it leads back to this
			-- same page and nothing in `before` objects to it. Anything
			-- `before` would have stopped is loaded the ordinary way, so
			-- its redirect or refusal is what the browser gets.
			mount.resolve = function(path: string, query: { [string]: string }): boolean
				local found, params = router.resolve("GET", path)
				if found ~= handler then
					return false
				end
				if opts.before then
					local probe = table.clone(request)
					probe.path, probe.query, probe.params = path, query, params
					if opts.before(probe) ~= nil then
						return false
					end
				end
				return true
			end
			local result = mount.result
			if Response.is(result) then
				mount:destroy()
				return result
			end
			local document = documentOf(result)
			if mount.counter == 0 and not forceLive then
				mount:destroy()
				return Response.html("<!doctype html>" .. Html.render(document))
			end
			mount.node = withScript(document, create "script" {
				src = `{clientPath}?v={Client.version}`,
				defer = true,
				["data-live"] = mount.id,
				["data-ws"] = socketPath,
				-- Tells the client to follow links in place.
				["data-routed"] = #mount.routers > 0,
			})
			Live.register(mount)
			return Response.html(mount:html(), mount.status)
		end
		router.get(pattern, handler)
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
		Graph.onError = Log.error
		Live.debug = opts.debug == true

		local connections: { [any]: Live.Connection } = {}

		local instance = server.serve({
			hostname = host,
			port = port,
			handler = function(raw, running): any
				if raw.method == "GET" and raw.path:match("^([^?]*)") == socketPath then
					if running:upgrade(raw) then
						return nil
					end
					return Response.text("expected a websocket", 426)
				end
				-- A raising handler would otherwise drop the connection with
				-- no status and no log line, which is the worst possible way
				-- to find out about a bug.
				local ok, result = Graph.try(self.handle, raw)
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
			websocket = {
				open = function(socket)
					connections[socket] = {
						send = function(text: string)
							socket:send(text)
						end,
					}
				end,
				message = function(socket, message)
					local connection = connections[socket]
					if connection == nil or type(message) ~= "string" then
						return
					end
					local ok, err = Graph.try(Live.receive, connection, message)
					if not ok then
						Log.error(`live: {err}`)
					end
				end,
				close = function(socket)
					local connection = connections[socket]
					connections[socket] = nil
					if connection then
						Live.closed(connection)
					end
				end,
			},
		})
		Log.info(`listening on http://{instance.hostname}:{instance.port}`)
		return instance
	end

	return self
end

return App
