--!strict
--[[
	State: sources, and the things that follow them.

	    local count = source(0)
	    local doubled = derive(function() return count() * 2 end)
	    effect(function() print(count(), doubled()) end)
	    count(count() + 1)

	A source is one function: call it with nothing to read, with a value to
	write. Reading inside a reactive scope subscribes that scope; writing
	re-runs every subscriber. The names and behaviour follow Vide.

	Where a source is created decides who shares it. One made at module level
	is shared by every visitor, so writing it updates every open page. One
	made inside a page function belongs to that one page view.
]]
local task = require("@lute/task")
local Graph = require("@web/graph")

local Reactive = {}

export type Source<T> = (() -> T) & ((value: T) -> T)

function Reactive.source<T>(initial: T): Source<T>
	local node = Graph.createSourceNode(initial)
	local function update(...: any): any
		if select("#", ...) == 0 then
			Graph.track(node)
			return node.cache
		end
		local value = (...)
		-- A table is always treated as changed unless frozen, so the usual
		-- "mutate, then write it back" works: `list(list())`.
		if node.cache == value and (type(value) ~= "table" or table.isfrozen(value)) then
			return value
		end
		node.cache = value
		Graph.updateDescendants(node)
		return value
	end
	return update :: any
end

-- A value computed from sources, recomputed when they change and only passed
-- on when the result differs.
function Reactive.derive<T>(compute: () -> T): () -> T
	local node = Graph.createNode(Graph.requireScope("derive"), compute :: any, nil)
	Graph.evaluate(node)
	return function(): T
		Graph.track(node :: any)
		return node.cache
	end
end

-- Run `callback` now and again whenever a source it read changes. What it
-- returns is handed back to it on the next run.
function Reactive.effect<T>(callback: (T) -> T, initial: T?)
	local node = Graph.createNode(Graph.requireScope("effect"), callback :: any, initial)
	Graph.evaluate(node)
end

--[[
	Run something when the current scope is destroyed or, in an effect, before
	it runs again. Takes a function, or anything with a destroy, disconnect or
	close method.
]]
function Reactive.cleanup(value: any)
	local scope = Graph.requireScope("cleanup")
	if type(value) == "function" then
		Graph.pushCleanup(scope, value)
		return
	end
	if type(value) == "table" then
		for _, name in { "destroy", "disconnect", "close", "Destroy", "Disconnect" } do
			local method = value[name]
			if type(method) == "function" then
				Graph.pushCleanup(scope, function()
					method(value)
				end)
				return
			end
		end
	end
	error("cleanup() takes a function or an object with a destroy, disconnect or close method", 2)
end

-- Read sources without subscribing to them.
function Reactive.untrack<T>(fn: () -> T): T
	local scope = Graph.getScope()
	if scope == nil then
		return fn()
	end
	local effect = scope.effect
	scope.effect = false
	local ok, result = Graph.try(fn)
	scope.effect = effect
	if not ok then
		error(result, 0)
	end
	return result
end

-- Accept either a value or a function returning one. Lets a component take
-- `title = "Players"` and `title = function() ... end` alike.
function Reactive.read<T>(value: T | (() -> T)): T
	if type(value) == "function" then
		return (value :: () -> T)()
	end
	return value :: T
end

Reactive.batch = Graph.batch

--[[
	Create a scope that owns everything made inside `fn`. Returns a function
	that destroys it, followed by whatever `fn` returned.

	A live page is a root that lasts as long as its browser tab. You only
	need this directly for state that belongs to no page: a background job,
	a test.
]]
function Reactive.root<T...>(fn: (destroy: () -> ()) -> T...): (() -> (), T...)
	local node = Graph.createNode(false, false, nil)
	local destroyed = false
	local function destroy()
		if destroyed then
			return
		end
		destroyed = true
		Graph.destroy(node)
	end
	Graph.pushScope(node)
	local result = table.pack(xpcall(fn :: any, Graph.traceback, destroy))
	Graph.popScope()
	if not result[1] then
		destroy()
		error(`error while running root():\n{result[2]}`, 0)
	end
	return destroy, table.unpack(result, 2, result.n)
end

export type Context<T> = (() -> T) & (<U>(value: T, fn: () -> U) -> U)

local contextCount = 0
local NIL = table.freeze({})

--[[
	A value handed down to every scope created inside a call, without passing
	it through each component.

	    local Viewer = context(nil)
	    Viewer(session, function() return Page() end)   -- provide
	    local who = Viewer()                            -- read, anywhere below
]]
function Reactive.context<T>(...: T): Context<T>
	contextCount += 1
	local id = contextCount
	local hasDefault = select("#", ...) > 0
	local default = (...)

	return function(...: any): any
		local scope: Graph.Node | false = Graph.getScope() or false
		if select("#", ...) == 0 then
			while scope do
				local held = scope.context
				local value = if held then held[id] else nil
				if value ~= nil then
					return if value == NIL then nil else value
				end
				scope = scope.owner
			end
			if hasDefault then
				return default
			end
			error("context read where none was provided, and it has no default", 2)
		end
		if not scope then
			error("cannot provide a context outside a scope", 2)
		end
		local value, fn = ...
		local inner = Graph.createNode(scope, false, nil)
		inner.context = { [id] = if value == nil then NIL else value }
		Graph.pushScope(inner)
		local result = table.pack(xpcall(fn, Graph.traceback))
		Graph.popScope()
		if not result[1] then
			error(`error while running context:\n{result[2]}`, 0)
		end
		return table.unpack(result, 2, result.n)
	end :: any
end

--[[
	Call `fn` every `seconds` until the current scope is destroyed.

	The server-side way to keep a page moving: a clock, a figure re-read from
	the database. `fn` runs outside any scope, like an event handler, so it
	may wait and should finish by writing a source.
]]
function Reactive.every(seconds: number, fn: () -> ())
	local scope = Graph.requireScope("every")
	local alive = true
	Graph.pushCleanup(scope, function()
		alive = false
	end)
	task.spawn(function()
		while true do
			task.wait(seconds)
			if not alive then
				break
			end
			local ok, err = Graph.try(fn)
			if not ok then
				Graph.onError(`every() error: {err}`)
			end
		end
	end)
end

export type Status = {
	loading: () -> boolean,
	error: () -> string?,
	refetch: () -> (),
	mutate: (value: any) -> (),
}

--[[
	Data that has to be waited for, as a source.

	    local player, status = resource(playerId, function(id)
	        return db:first("select * from players where id = ?", id)
	    end)

	Effects cannot wait, so this is how something slow follows a source:
	whenever `key()` changes, `fetch` is called with the new key and its
	result becomes the value. Called with a fetcher alone, it loads once.

	`player()` is the latest value, and keeps the previous one while a new
	load is running. `status.loading()` and `status.error()` are sources too;
	`status.refetch()` loads again and `status.mutate(v)` sets the value by
	hand. A key of nil or false means "nothing to load yet".

	The first load is waited for when that is possible, which it is in a
	page function. The page is then sent with its data in it and no loading
	state flashes by. Later loads run in the background. If a newer load
	finishes before an older one, the older result is dropped.
]]
function Reactive.resource<K, T>(key: any, fetch: ((key: K) -> T)?): (() -> T?, Status)
	local fetcher: (any) -> any = fetch or key
	local readKey: () -> any = if fetch then key else function()
		return true
	end
	local scope = Graph.requireScope("resource")

	local value = Reactive.source(nil :: any)
	local loading = Reactive.source(false)
	local failure = Reactive.source(nil :: string?)
	local generation = 0
	local alive = true
	Graph.pushCleanup(scope, function()
		alive = false
	end)

	local function load(with: any)
		generation += 1
		local mine = generation
		loading(true)
		local ok, result = Graph.try(fetcher, with)
		if mine ~= generation or not alive then
			return -- a newer load has started, or nobody is left to tell
		end
		Graph.batch(function()
			if ok then
				value(result)
				failure(nil)
			else
				failure(tostring(result))
			end
			loading(false)
		end)
		if not ok then
			Graph.onError(`resource error: {result}`)
		end
	end

	local function start(with: any)
		if Graph.canYield() then
			load(with)
		else
			task.spawn(load, with)
		end
	end

	local loadedKey: any = nil
	local first = true
	local initial = Reactive.untrack(readKey)
	if initial and Graph.canYield() then
		loadedKey = initial
		load(initial)
	end

	Reactive.effect(function()
		local current = readKey()
		local skip = first and loadedKey ~= nil and current == loadedKey
		first = false
		if current and not skip then
			task.spawn(load, current)
		end
	end)

	local status: Status = {
		loading = loading,
		error = failure,
		refetch = function()
			local current = Reactive.untrack(readKey)
			if current then
				start(current)
			end
		end,
		mutate = function(next: any)
			value(next)
		end,
	}
	return value, status
end

return Reactive
