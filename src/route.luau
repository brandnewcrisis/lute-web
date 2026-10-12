--!strict
--[[
	Routing inside a page: one document, many URLs.

	    app.page("/*", function()
	        return Layout {
	            route {
	                ["/"] = Home,
	                ["/players"] = PlayerList,
	                ["/players/:id"] = PlayerPage,
	                ["*"] = NotFound,
	            },
	        }
	    end)

	`route` is `switch` keyed by the URL. Following a link on the page does
	not load a new document: the browser tells the server where it is going,
	the server builds the component for that URL in place of the old one, and
	the address bar is updated. Everything outside the `route` stays exactly
	as it was, with its state.

	Unlike `switch`, the swap is not an effect. It runs where the navigation
	was asked for, a handler or the page function, so the component being
	built may wait on a database, and a `resource` in it has its first load
	done before the page is shown.
]]
local Graph = require("@web/graph")
local Reactive = require("@web/reactive")
local Html = require("@web/html")
local Live = require("@web/live")

local Route = {}

export type Params = { [string]: string }

type Pattern = {
	pattern: string,
	segments: { string },
	wildcard: boolean,
	score: number,
	component: (params: () -> Params) -> any,
}

local function split(path: string): { string }
	local segments = {}
	for segment in path:gmatch("[^/]+") do
		table.insert(segments, segment)
	end
	return segments
end

--[[
	Patterns are the same as the app's: "/players/:id", with a final "/*"
	taking everything below. A bare "*" is the page shown when nothing else
	fits. The table has no order, so which pattern wins is decided by how
	specific it is: no wildcard beats a wildcard, then more fixed segments,
	then more segments.
]]
local function compile(pattern: string, component: any): Pattern
	if type(component) ~= "function" then
		error(`route: "{pattern}" must map to a component function`, 0)
	end
	local segments = split(pattern)
	local wildcard = segments[#segments] == "*"
	if wildcard then
		table.remove(segments)
	end
	local fixed = 0
	for _, segment in segments do
		if segment:sub(1, 1) ~= ":" then
			fixed += 1
		end
	end
	return {
		pattern = pattern,
		segments = segments,
		wildcard = wildcard,
		score = (if wildcard then 0 else 10000) + fixed * 100 + #segments,
		component = component,
	}
end

local function match(pattern: Pattern, wanted: { string }): Params?
	if pattern.wildcard then
		if #wanted < #pattern.segments then
			return nil
		end
	elseif #wanted ~= #pattern.segments then
		return nil
	end
	local params: Params = {}
	for index, segment in pattern.segments do
		if segment:sub(1, 1) == ":" then
			params[segment:sub(2)] = wanted[index]
		elseif segment ~= wanted[index] then
			return nil
		end
	end
	if pattern.wildcard then
		params["*"] = table.concat(wanted, "/", #pattern.segments + 1)
	end
	return params
end

local function sameParams(a: Params, b: Params): boolean
	for key, value in a do
		if b[key] ~= value then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local HOME: Live.Location = table.freeze({ path = "/", query = table.freeze({}), url = "/" }) :: any

--[[
	Where the page is: `location().path`, `.query`, `.url`.

	A source, so anything that reads it follows the address bar. Outside a
	live page it is always "/".
]]
function Route.location(): Live.Location
	local mount = Live.current()
	if mount == nil then
		return HOME
	end
	return mount.location()
end

--[[
	Show the component whose pattern matches the current URL.

	Each component is given a source of its parameters: `params().id`. When
	the URL changes but still fits the same pattern ("/players/1" to
	"/players/2"), the component is kept and the source changes, so read it
	inside a function, or feed it to a `resource`, as you would any source.
	When the pattern changes, the old component is destroyed once the new
	one has been built.

	Routes nest. A component under "/players/*" can hold a `route` of its
	own for what comes below, and is kept while navigating among them.
]]
function Route.route(map: { [string]: (params: () -> Params) -> any }): () -> any
	local scope = Graph.requireScope("route")
	local mount: Live.Mount? = Graph.mountOf(scope)

	local patterns: { Pattern } = {}
	for pattern, component in map do
		table.insert(patterns, compile(pattern, component))
	end
	table.sort(patterns, function(a: Pattern, b: Pattern)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.pattern < b.pattern
	end)

	local output = Reactive.source(nil :: any)
	local shown: Pattern? = nil
	local shownScope: Graph.Node? = nil
	local shownParams: Reactive.Source<Params>? = nil
	local generation = 0

	local entry: Live.RouterEntry = { alive = true, update = function() end }

	local function update()
		local location: Live.Location = if mount then Reactive.untrack(mount.location) else HOME
		local wanted = split(location.path)
		local found: Pattern? = nil
		local params: Params = {}
		for _, pattern in patterns do
			local matched = match(pattern, wanted)
			if matched then
				found, params = pattern, matched
				break
			end
		end

		if found ~= nil and found == shown and shownParams then
			if not sameParams(Reactive.untrack(shownParams), params) then
				shownParams(params)
			end
			return
		end

		generation += 1
		local mine = generation
		local built: Graph.Node? = nil
		local holder: Reactive.Source<Params>? = nil
		local object: any = nil

		if found then
			-- Built in a scope of its own, on the coroutine that asked, so
			-- it may wait. The page being left stays up until this is done.
			local node = Graph.createNode(scope, false, nil)
			local held = Reactive.source(params)
			Graph.pushScope(node)
			local ok, result = Graph.try(found.component, held)
			Graph.popScope()
			if not ok then
				Graph.destroy(node)
				error(result, 0)
			end
			built, holder, object = node, held, result
		end

		if mine ~= generation or not entry.alive then
			-- Another navigation overtook this one while it was waiting.
			if built then
				Graph.destroy(built)
			end
			return
		end

		if shownScope then
			Graph.destroy(shownScope)
		end
		shown, shownScope, shownParams = found, built, holder
		-- "*" is the not-found page; so is matching nothing at all. Only
		-- the first response can say so, later moves have no status.
		if mount and (found == nil or found.pattern == "*") then
			mount.status = 404
		end
		output(object)
	end

	entry.update = update
	if mount then
		table.insert(mount.routers, entry)
	end
	Graph.pushCleanup(scope, function()
		entry.alive = false
		if mount then
			local index = table.find(mount.routers, entry)
			if index then
				table.remove(mount.routers, index)
			end
		end
	end)

	update()
	return output
end

--[[
	An `<a>` that knows whether it points at where the page is.

	    link { href = "/players", "Players" }

	Any link on a routed page navigates in place; this one adds
	`aria-current="page"` when its `href` is the current path, and
	`aria-current="true"` when the current path lies beneath it, which is
	all a stylesheet needs to mark the active item in a menu.
]]
function Route.link(props: Html.Props): Html.Node
	local href = props.href
	if type(href) ~= "string" then
		error("link: href must be a string", 2)
	end
	local target = href:match("^([^?#]*)") or href
	return Html.create("a", {
		props,
		["aria-current"] = function(): string?
			local path = Route.location().path
			if path == target then
				return "page"
			end
			if target ~= "/" and path:sub(1, #target + 1) == target .. "/" then
				return "true"
			end
			return nil
		end,
	})
end

return Route
