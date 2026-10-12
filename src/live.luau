--!strict
--[[
	Live pages: a reactive scope on the server for each open browser tab.

	Rendering a page builds its elements inside a root scope and keeps that
	scope alive. Every function used as a property or child became an effect
	in it. When a source changes, those effects run again here, and what they
	produced is sent to the browser as a patch: this region now holds this
	markup, this attribute now has this value. Clicks and input travel the
	other way and call handlers that close over the same sources.

	The transport is one WebSocket per tab. This file never touches the socket
	itself: a connection is anything with a `send`, which is what lets the
	whole protocol be tested without a network.

	Patches are not kept for a browser that is not listening. A page whose
	socket dropped is marked stale, and on reconnect it is sent its whole
	body as it now stands; the client folds that into what it has. That one
	rule covers a lost frame, a laptop lid and the gap between the first
	render and the socket opening.
]]
local task = require("@lute/task")
local Graph = require("@web/graph")
local Reactive = require("@web/reactive")
local Flow = require("@web/flow")
local Html = require("@web/html")
local Json = require("@web/json")
local Bytes = require("@web/bytes")
local Form = require("@web/form")

local Live = {}

-- Seconds a page is kept after its socket closes, so a dropped connection
-- or a laptop waking up can pick it back up with its state intact.
Live.linger = 30
-- Seconds a freshly rendered page waits for its socket before it is
-- dropped. Crawlers, curl and link previews never connect.
Live.connectWithin = 15
-- Pages held at once before the ones nobody is connected to are dropped
-- early. A ceiling on what a loop of anonymous GETs can make the server hold.
Live.maxMounts = 5000
-- Include handler error text in what the browser is told. For development.
Live.debug = false
-- Largest message accepted from a browser, in bytes. An event is a few
-- hundred; a form with a long essay in it is a few thousand.
Live.maxMessage = 1024 * 1024

export type Event = {
	type: string,
	value: string?,
	checked: boolean?,
	key: string?,
	name: string?,
	form: { [string]: string }?,
	ctrl: boolean?,
	shift: boolean?,
	alt: boolean?,
	meta: boolean?,
}

-- Where a page is: what `location()` returns.
export type Location = {
	path: string,
	query: { [string]: string },
	url: string,
}

-- A `route` on the page. Told to look again whenever the location moves.
export type RouterEntry = {
	alive: boolean,
	update: () -> (),
}

export type Connection = {
	send: (text: string) -> (),
	mount: any?,
}

local MountMeta = {}
MountMeta.__index = MountMeta

type MountData = {
	id: string,
	node: any,
	result: any,
	counter: number,
	handlers: { [number]: (Event) -> () },
	pending: { { node: any, what: any } },
	queued: { [any]: boolean },
	outbox: { any },
	connection: Connection?,
	stale: boolean,
	scheduled: boolean,
	deadline: number?,
	destroyed: boolean,
	destroyRoot: () -> (),
	-- routing; see route.luau
	location: Reactive.Source<Location>,
	routers: { RouterEntry },
	-- Whether a URL belongs to this same page, so it can be moved to without
	-- loading a new document. Set by the app, which knows its routes.
	resolve: ((path: string, query: { [string]: string }) -> boolean)?,
	-- Status for the first response, if the page wants other than 200.
	status: number?,
}

export type Mount = typeof(setmetatable({} :: MountData, MountMeta))

local mounts: { [string]: Mount } = {}
local mountCount = 0
local reaping = false

-- Which page an event handler is running for, by coroutine, so `navigate`
-- and `emit` know where to send without being handed the page.
local running: { [thread]: Mount } = setmetatable({}, { __mode = "k" }) :: any

function MountMeta.allocate(self: Mount): number
	self.counter += 1
	return self.counter
end

function MountMeta.handler(self: Mount, fn: (Event) -> ()): number
	local id = self:allocate()
	self.handlers[id] = fn
	-- Dropped with the scope that made it, so a click on markup that has
	-- since been replaced finds nothing to call.
	Graph.pushCleanup(Graph.requireScope("create"), function()
		self.handlers[id] = nil
	end)
	return id
end

local flush: (mount: Mount) -> ()

local function schedule(mount: Mount)
	if mount.scheduled then
		return
	end
	mount.scheduled = true
	task.defer(function()
		flush(mount)
	end)
end

--[[
	Called by a binding when its value moved.

	Only notes which binding; the value is read when the patch is written.
	That way a binding that changes five times in one handler is sent once,
	with what it ended on.
]]
function MountMeta.touch(self: Mount, node: any, what: any?)
	-- An attribute binding is its own slot table; a region or a text
	-- binding is the node.
	local target = if type(what) == "table" then what else node
	if self.connection == nil then
		-- Nobody to tell. The reconnect will send everything, and whatever
		-- was last sent for this binding no longer says what the browser has.
		self.stale = true
		target.sent = nil
		return
	end
	if self.queued[target] then
		return
	end
	self.queued[target] = true
	table.insert(self.pending, { node = node, what = what })
	schedule(self)
end

local function post(mount: Mount, message: any)
	table.insert(mount.outbox, message)
	if mount.connection then
		schedule(mount)
	end
end

function flush(mount: Mount)
	mount.scheduled = false
	local connection = mount.connection
	if connection == nil or mount.destroyed then
		return
	end

	local patches = {}
	local pending = mount.pending
	mount.pending = {}
	table.clear(mount.queued)
	for _, entry in pending do
		local node, what = entry.node, entry.what
		if what == nil then
			local html = Html.inner(node)
			-- Skip a region that came out the same. Only worth remembering
			-- for small ones; a long list re-sent unchanged costs the wire
			-- once, remembering every list would cost memory for good.
			if node.sent ~= html then
				node.sent = if #html <= 256 then html else nil
				table.insert(patches, { r = node.id, h = html })
			end
		elseif what == "text" then
			if node.sent ~= node.text then
				node.sent = node.text
				table.insert(patches, { x = node.lid, v = node.text })
			end
		else
			local value = what.value
			if what.sent ~= value then
				what.sent = value
				-- No `v` removes the attribute; an empty one is a bare attribute.
				table.insert(patches, { a = node.lid, n = what.name, v = if value == true then "" else value })
			end
		end
	end

	if #patches > 0 then
		connection.send(Json.encode({ t = "p", p = patches }))
	end
	if #mount.outbox > 0 then
		local outbox = mount.outbox
		mount.outbox = {}
		for _, message in outbox do
			connection.send(Json.encode(message))
		end
	end
end

function MountMeta.flush(self: Mount)
	flush(self)
end

-- The whole document as it stands now.
function MountMeta.html(self: Mount): string
	return "<!doctype html>" .. Html.render(self.node)
end

function MountMeta.destroy(self: Mount)
	if self.destroyed then
		return
	end
	self.destroyed = true
	if rawequal(mounts[self.id], self) then
		mounts[self.id] = nil
		mountCount -= 1
	end
	local connection = self.connection
	if connection then
		connection.mount = nil
		self.connection = nil
	end
	self.destroyRoot()
end

local function reap()
	while next(mounts) ~= nil do
		task.wait(1)
		local now = os.clock()
		for _, mount in mounts do
			if mount.deadline and now >= mount.deadline then
				mount:destroy()
			end
		end
	end
	reaping = false
end

-- Make room by dropping the unattached page closest to expiring anyway.
local function evict()
	local soonest: Mount? = nil
	for _, mount in mounts do
		local deadline = mount.deadline
		if deadline and (soonest == nil or deadline < (soonest.deadline :: number)) then
			soonest = mount
		end
	end
	if soonest then
		soonest:destroy()
	end
end

--[[
	Build a page: run `component` inside a new root scope and keep the scope.

	The mount is not yet reachable by a browser; `register` does that once
	the caller has decided the result is a page worth keeping. `component`
	may yield. A mount that turns out to have nothing reactive in it has a
	`counter` of zero and can simply be destroyed and served as plain HTML.
]]
function Live.mount(component: () -> any, at: Location?): Mount
	local mount: Mount = setmetatable({
		id = Bytes.token(18),
		node = nil,
		result = nil,
		counter = 0,
		handlers = {},
		pending = {},
		queued = {},
		outbox = {},
		connection = nil,
		stale = false,
		scheduled = false,
		deadline = nil,
		destroyed = false,
		destroyRoot = function() end,
		location = Reactive.source(at or { path = "/", query = {}, url = "/" }),
		routers = {},
		resolve = nil,
		status = nil,
	} :: MountData, MountMeta)

	local destroyRoot, result = Reactive.root(function()
		local scope = Graph.getScope() :: Graph.Node
		scope.mount = mount
		return component()
	end)
	mount.destroyRoot = destroyRoot
	mount.result = result
	mount.node = result
	return mount
end

-- Make a mount reachable by its id and start its connect timer.
function Live.register(mount: Mount)
	if mountCount >= Live.maxMounts then
		evict()
	end
	mounts[mount.id] = mount
	mountCount += 1
	mount.deadline = os.clock() + Live.connectWithin
	-- What was rendered is complete as of now; nothing is owed for changes
	-- made while the page was being built.
	mount.stale = false
	if not reaping then
		reaping = true
		task.spawn(reap)
	end
end

function Live.find(id: string): Mount?
	return mounts[id]
end

function Live.count(): number
	return mountCount
end

local function attach(mount: Mount, connection: Connection)
	local previous = mount.connection
	if previous and previous ~= connection then
		-- The same page opened twice (a restored tab, a duplicate). The
		-- newer one takes over and the older is told to start again.
		previous.mount = nil
		previous.send(Json.encode({ t = "gone" }))
		mount.stale = true
	end
	mount.connection = connection
	connection.mount = mount
	mount.deadline = nil
	if mount.stale then
		mount.stale = false
		mount.pending = {}
		table.clear(mount.queued)
		connection.send(Json.encode({ t = "sync", h = mount:html() }))
	end
	flush(mount)
end

local function detach(mount: Mount)
	mount.connection = nil
	mount.stale = true
	mount.deadline = os.clock() + Live.linger
end

--[[
	Run an event handler for a page.

	Handlers run outside any reactive scope, exactly as a connected callback
	does in Vide, so they may wait on a database or a request. Returns false
	and the error if the handler raised.
]]
function Live.dispatch(mount: Mount, id: number, event: Event): (boolean, string?)
	local handler = mount.handlers[id]
	if handler == nil then
		return true, nil -- the element has been replaced since; nothing to do
	end
	local thread = coroutine.running()
	running[thread] = mount
	local ok, err = Graph.try(handler, event)
	running[thread] = nil
	if not ok then
		return false, tostring(err)
	end
	return true, nil
end

local function eventFrom(data: any): Event
	local event: Event = { type = "" }
	if type(data) ~= "table" then
		return event
	end
	for _, field in { "type", "value", "key", "name" } do
		if type(data[field]) == "string" then
			(event :: any)[field] = data[field]
		end
	end
	for _, field in { "checked", "ctrl", "shift", "alt", "meta" } do
		if type(data[field]) == "boolean" then
			(event :: any)[field] = data[field]
		end
	end
	if type(data.form) == "table" then
		local form: { [string]: string } = {}
		for name, value in data.form do
			if type(name) == "string" and type(value) == "string" then
				form[name] = value
			end
		end
		event.form = form
	end
	return event
end

--[[
	Handle one message from a browser.

	Everything in it is untrusted. The page id is the credential: it is 144
	random bits handed only to whoever was served the page, so holding it is
	what proves a message comes from that page view and not another site.
]]
function Live.receive(connection: Connection, text: string)
	if #text > Live.maxMessage then
		return
	end
	local message = Json.decode(text)
	if type(message) ~= "table" then
		return
	end
	local kind = message.t

	if kind == "hello" then
		local mount = if type(message.m) == "string" then mounts[message.m] else nil
		if mount == nil then
			connection.send(Json.encode({ t = "gone" }))
			return
		end
		attach(mount, connection)
		return
	end

	local mount: Mount? = connection.mount
	if mount == nil then
		return
	end

	if kind == "e" then
		local ok, err = true, nil :: string?
		if type(message.h) == "number" then
			ok, err = Live.dispatch(mount, message.h, eventFrom(message.d))
		end
		if not ok then
			Graph.onError(`event handler error: {err}`)
		end
		if mount.destroyed or mount.connection ~= connection then
			return
		end
		-- Patches first, then the acknowledgement, so by the time the
		-- browser clears the busy state the page already shows the result.
		flush(mount)
		connection.send(Json.encode({
			t = "ack",
			n = message.n,
			ok = ok,
			m = if not ok and Live.debug then err else nil,
		}))
	elseif kind == "nav" then
		-- A link was followed, or back/forward was pressed.
		local url = message.u
		local ok, err = true, nil :: any
		if type(url) == "string" then
			local thread = coroutine.running()
			running[thread] = mount
			local moved
			ok, moved = Graph.try(Live.visit, mount, url)
			running[thread] = nil
			if not ok then
				err = moved
				Graph.onError(`navigation error: {err}`)
			elseif moved then
				-- After back/forward the browser is already at the URL.
				if message.pop ~= true then
					post(mount, { t = "url", u = url })
				end
			else
				-- Not one of this page's own: load it the ordinary way.
				post(mount, if message.pop == true then { t = "reload" } else { t = "go", u = url })
			end
		end
		if mount.destroyed or mount.connection ~= connection then
			return
		end
		flush(mount)
		connection.send(Json.encode({
			t = "ack",
			n = message.n,
			ok = ok,
			m = if not ok and Live.debug then tostring(err) else nil,
		}))
	elseif kind == "ping" then
		connection.send('{"t":"pong"}')
	elseif kind == "bye" then
		mount:destroy()
	end
end

-- The socket behind a connection closed.
function Live.closed(connection: Connection)
	local mount: Mount? = connection.mount
	connection.mount = nil
	if mount and mount.connection == connection then
		detach(mount)
	end
end

--[[
	The page the calling code belongs to: the one whose handler is running,
	or the one being built.
]]
function Live.current(): Mount?
	local mount = running[coroutine.running()]
	if mount then
		return mount
	end
	return Graph.mountOf(Graph.getScope())
end

local function requireCurrent(what: string): Mount
	local mount = Live.current()
	if mount == nil then
		error(`{what}() must be called from a live page: in its component or one of its event handlers`, 3)
	end
	return mount :: Mount
end

--[[
	Move a page to another of its own URLs without loading a new document.

	Sets the page's location and has each `route` on it look again, building
	whatever now matches. May yield, since building a page may. Returns false,
	having done nothing, if the URL is not one this page can show by itself:
	it has no routes, or the URL belongs to a different page or a plain route.
]]
function Live.visit(mount: Mount, url: string): boolean
	-- Paths on this site only: no scheme, no "//other.host".
	if url:sub(1, 1) ~= "/" or url:sub(2, 2) == "/" or url:sub(2, 2) == "\\" then
		return false
	end
	local path, search = url:match("^([^?#]*)%??([^#]*)")
	local query = Form.parse(search or "")
	if #mount.routers == 0 then
		return false
	end
	if mount.resolve and not mount.resolve(path :: string, query) then
		return false
	end
	mount.location({ path = path :: string, query = query, url = url })
	-- A copy, because building a page adds routers and replacing one
	-- removes them. Parents come first, so by the time a nested router is
	-- asked it is either still wanted or already gone.
	for _, router in table.clone(mount.routers) do
		if router.alive then
			router.update()
		end
	end
	return true
end

--[[
	Send the browser to another URL.

	The way to move on from an event handler, which has no response of its
	own to redirect with. A URL that one of the page's own routes can show
	is moved to in place; anything else is an ordinary navigation. Pass
	`{ replace = true }` to take the current entry's place in history.
]]
function Live.navigate(url: string, options: { replace: boolean? }?)
	local mount = requireCurrent("navigate")
	if Graph.canYield() and Live.visit(mount, url) then
		post(mount, { t = "url", u = url, r = if options and options.replace then true else nil })
	else
		post(mount, { t = "go", u = url, r = if options and options.replace then true else nil })
	end
end

-- Reload the page in the browser, building it afresh.
function Live.reload()
	post(requireCurrent("reload"), { t = "reload" })
end

--[[
	Fire a DOM event on `document` in the browser.

	The escape hatch for the few things that have to happen client-side: a
	script of your own listens for the name and does the focusing, the
	scrolling or the copy to clipboard.
]]
function Live.emit(name: string, detail: any?)
	post(requireCurrent("emit"), { t = "ev", n = name, d = detail })
end

-- Destroy every page. For tests and shutdown.
function Live.reset()
	for _, mount in mounts do
		mount:destroy()
	end
end

-- Give list items made by `values` an identity the browser can follow, so a
-- row that moves is moved and not rewritten into its neighbour.
Flow.stamp = function(object: any)
	if Html.isNode(object) and object.kind == "el" and object.key == nil then
		local mount = Graph.mountOf(Graph.getScope())
		if mount then
			object.key = "v" .. mount:allocate()
		end
	end
end

return Live
