--!strict
--[[
	Control flow: content that comes and goes, and lists.

	Each of these returns a function to use as a child. What they add over a
	plain function child is memory: a plain function rebuilds everything it
	returns each time it runs, while these keep the scope of whatever did not
	change. A row that is still in the list keeps its own state.

	As in Vide, minus the `present` source and the delayed destroy that exist
	there to drive exit animations.
]]
local Graph = require("@web/graph")
local Reactive = require("@web/reactive")

local source, effect, derive = Reactive.source, Reactive.effect, Reactive.derive

local Flow = {}

-- Set by html.luau so list items can be given an identity the browser can
-- follow when they move. Kept as a hook so this module knows nothing of HTML.
Flow.stamp = function(_object: any) end

--[[
	Run `fn` in a scope that outlives the effect calling it.

	The new scope hangs off the effect's owner, so it survives the effect
	running again and is destroyed either by hand or when that owner goes.
]]
local function branch<T>(fn: () -> T): (() -> (), T)
	local current = Graph.getScope()
	local owner = if current then current.owner else false
	if not current or not owner then
		error("branch() must be called from an effect that has an owner", 0)
	end
	local node = Graph.createNode(owner :: Graph.Node, false, nil)
	local function destroy()
		Graph.destroy(node)
	end
	Graph.pushScope(node)
	local ok, result = Graph.try(fn)
	Graph.popScope()
	if not ok then
		destroy()
		error(result, 0)
	end
	return destroy, result
end

--[[
	Show one of several components, chosen by the value of `input`.

	    switch(tab) {
	        players = function() return PlayerList() end,
	        bans = function() return BanList() end,
	    }

	A value with no entry shows nothing. The component is built when its key
	is first chosen and destroyed when another takes over.
]]
function Flow.switch<K>(input: () -> K): (map: { [K]: () -> any }) -> () -> any
	return function(map)
		local output = source(nil :: any)
		local shownKey: any = nil
		local destroyShown: (() -> ())? = nil

		effect(function()
			local key: any = input()
			if key == shownKey and destroyShown ~= nil then
				return
			end
			if destroyShown then
				destroyShown()
				destroyShown = nil
			end
			shownKey = key
			local component = if key ~= nil then map[key] else nil
			if component == nil then
				output(nil)
				return
			end
			if type(component) ~= "function" then
				error("switch: each entry must be a function returning what to show", 0)
			end
			local destroy, object = branch(component)
			destroyShown = destroy
			output(object)
		end)

		return output
	end
end

--[[
	Show `component` while `input` is truthy, `fallback` (if given) otherwise.

	The component is handed a source of the truthy value, so it can go on
	reading it without re-checking for nil, and is kept while the value
	changes from one truthy thing to another.
]]
function Flow.show<T>(input: () -> T?, component: (value: () -> T) -> any, fallback: (() -> any)?): () -> any
	local present = source(nil :: any)
	effect(function()
		local value = input()
		if value then
			present(value)
		end
	end)
	local truthy = derive(function()
		return not not input()
	end)
	return Flow.switch(truthy)({
		[true] = function()
			return component(present)
		end,
		[false] = fallback :: any,
	})
end

type Entry = {
	destroy: () -> (),
	object: any,
	held: any,
	update: any,
	seen: number,
}

--[[
	Shared by `indexes` and `values`: keep one scope per key of `input`,
	create and destroy them as keys come and go, and put out the objects in
	the order the input lists them.
]]
local function each(input: () -> { [any]: any }, byValue: boolean, component: (...any) -> any): () -> { any }
	local entries: { [any]: Entry } = {}
	local output = source({} :: { any })
	local pass = 0

	effect(function()
		local data = input()
		pass += 1
		local objects = {}
		local moved = false

		for index, value in data do
			-- `values` tracks the item and tells it where it now sits;
			-- `indexes` tracks the position and tells it what it now holds.
			local key, held = index, value
			if byValue then
				key, held = value, index
			end
			local entry = entries[key]
			if entry == nil then
				local holder = source(held)
				local destroy, object = branch(function()
					if byValue then
						return component(key, holder)
					end
					return component(holder, key)
				end)
				if byValue then
					Flow.stamp(object)
				end
				entry = { destroy = destroy, object = object, held = held, update = holder, seen = pass }
				entries[key] = entry
				moved = true
			else
				if entry.seen == pass then
					error("values(): the same value appears twice in the list; each item needs its own identity", 0)
				end
				entry.seen = pass
				if entry.held ~= held then
					entry.held = held
					entry.update(held)
					-- An item at a new position has to be put out again in
					-- its new place even though nothing was created.
					moved = moved or byValue
				end
			end
			table.insert(objects, entry.object)
		end

		for key, entry in entries do
			if entry.seen ~= pass then
				entry.destroy()
				entries[key] = nil
				moved = true
			end
		end

		if moved then
			output(objects)
		end
	end)

	return output
end

--[[
	A list where each ITEM keeps its scope.

	    values(todos, function(todo, index)
	        return create "li" { todo.text }
	    end)

	The component runs once per distinct item and is given a source of its
	index. Reordering, inserting and removing touch only what moved. Use this
	for lists of things that have an identity: rows from a table, players,
	messages. Items must be distinct values, which tables always are.
]]
function Flow.values<V>(input: () -> { [any]: V }, component: (value: V, index: () -> any) -> any): () -> { any }
	return each(input, true, component)
end

--[[
	A list where each POSITION keeps its scope.

	    indexes(scores, function(score, index)
	        return create "li" { score }
	    end)

	The component runs once per index and is given a source of the value
	there. Use this when the values are plain strings or numbers that may
	repeat, or when the list has a fixed shape and only its contents change.
]]
function Flow.indexes<V>(input: () -> { [any]: V }, component: (value: () -> V, index: any) -> any): () -> { any }
	return each(input, false, component)
end

--[[
	Contain a failure to one part of the page.

	    boundary(function()
	        return PlayerCard(player)
	    end, function(message, retry)
	        return create "p" { class = "error", "This card failed to load." }
	    end)

	If `component` raises while it is being built, or an effect inside it
	raises later, everything it made is destroyed and `fallback` is shown in
	its place, given the error and a function that tries again. The error is
	logged either way. Without one, an error while building takes the whole
	page with it, and an error in a later rerun leaves stale content behind.
]]
function Flow.boundary(component: () -> any, fallback: (message: string, retry: () -> ()) -> any): () -> any
	local output = source(nil :: any)
	-- A fresh table per write, so writing "no error" again is still a
	-- change and is what makes retry rebuild.
	local state = source({} :: { error: string? })
	local destroyShown: (() -> ())? = nil

	local function retry()
		state({})
	end

	effect(function()
		local failed = state().error
		if destroyShown then
			destroyShown()
			destroyShown = nil
		end

		if failed == nil then
			local caught: string? = nil
			local destroy, object = branch(function()
				local scope = Graph.getScope() :: Graph.Node
				scope.catch = function(message: string)
					state({ error = message })
				end
				local ok, result = Graph.try(component)
				if not ok then
					caught = tostring(result)
					return nil
				end
				return result
			end)
			if caught == nil then
				destroyShown = destroy
				output(object)
				return
			end
			-- Failed while building. Show the fallback from this same run:
			-- writing `state` here would rerun the effect that is running.
			destroy()
			Graph.onError(`boundary caught: {caught}`)
			failed = caught
		end

		local destroy, object = branch(function()
			return fallback(failed :: string, retry)
		end)
		destroyShown = destroy
		output(object)
	end)

	return output
end

Flow.branch = branch

return Flow
