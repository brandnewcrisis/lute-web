--!strict
--[[
	The reactive graph: scopes, ownership, and update propagation.

	This is Vide's graph (https://github.com/centau/vide, MIT) carried over to
	a server. Two things had to change for that, and they are the only places
	this departs from the original:

	  * The scope stack is per coroutine. Vide runs on one thread and keeps
	    one global stack; a server runs a coroutine per request, and a page
	    function that waits on a database must not leave its scope sitting
	    on top of somebody else's.
	  * A failing effect cannot be allowed to throw out of the source that
	    triggered it. One visitor's broken effect would otherwise abort the
	    update for everyone else subscribed to the same source. Re-runs
	    report to `onError` and the queue carries on; only the first run of
	    an effect, which happens where it is created, raises.

	Stable scopes (a root, a component body) may yield. Reactive scopes (the
	function given to `effect` or `derive`, or a function used as a property
	or child) may not: an effect that waits would leave the graph half updated
	while other requests read it.
]]
local Graph = {}

export type SourceNode = {
	cache: any,
	[number]: Node,
}

export type Node = {
	cache: any,
	effect: ((any) -> any) | false,
	cleanups: { () -> () } | false,
	context: { [number]: any } | false,
	owned: { Node } | false,
	owner: Node | false,
	parents: { SourceNode },
	-- The live page this scope belongs to, set on the page's root scope and
	-- found by walking owners. See live.luau.
	mount: any?,
	-- Set on an error boundary's scope: told when an effect below it fails
	-- on a rerun. See flow.luau.
	catch: ((message: string) -> ())?,
	[number]: Node,
}

-- Where errors from effect re-runs and cleanups go. The app points this at
-- its log; on its own the library prints.
Graph.onError = function(message: string)
	print(message)
end

local stacks: { [thread]: { Node } } = setmetatable({}, { __mode = "k" }) :: any

-- Coroutines running a reactive function right now. They are the ones that
-- must not yield, which is how `resource` decides whether it may wait.
local reactive: { [thread]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function getScope(): Node?
	local stack = stacks[coroutine.running()]
	if stack == nil then
		return nil
	end
	return stack[#stack]
end

local function pushScope(node: Node)
	local thread = coroutine.running()
	local stack = stacks[thread]
	if stack == nil then
		stack = {}
		stacks[thread] = stack
	end
	table.insert(stack, node)
end

local function popScope()
	local thread = coroutine.running()
	local stack = stacks[thread]
	if stack == nil then
		return
	end
	table.remove(stack)
	if #stack == 0 then
		stacks[thread] = nil
	end
end

local function traceback(err: any): string
	return debug.traceback(tostring(err), 2)
end

-- xpcall with a traceback, typed loosely enough to be used on anything.
local function try(fn: any, ...: any): (boolean, any)
	return (xpcall :: any)(fn, traceback, ...)
end

--[[
	Run `fn` with `node` as its scope, refusing to let it yield.

	The call happens on a coroutine of its own so a yield can be seen: if the
	coroutine is not dead when control comes back, the function is waiting on
	something. Its scope stack is dropped at that point, so whatever it does
	when the scheduler resumes it later is no longer tracked.
]]
local function guarded(node: Node?, fn: (any) -> any, arg: any): (boolean, any)
	local thread = coroutine.create(xpcall)
	if node then
		stacks[thread] = { node }
	end
	reactive[thread] = true
	local resumed, ok, result = coroutine.resume(thread, fn, traceback, arg)
	stacks[thread] = nil
	reactive[thread] = nil
	if not resumed then
		return false, tostring(ok)
	end
	if coroutine.status(thread) ~= "dead" then
		return false, "attempt to yield inside a reactive scope: do the waiting in the page function or an event handler, then set a source"
	end
	return ok, result
end

local function createNode(owner: Node | false, effect: ((any) -> any) | false, value: any): Node
	local node: Node = {
		cache = value,
		effect = effect,
		cleanups = false,
		context = false,
		owner = owner,
		owned = false,
		parents = {},
	}
	if owner then
		if owner.owned then
			table.insert(owner.owned, node)
		else
			owner.owned = { node }
		end
	end
	return node
end

local function createSourceNode(value: any): SourceNode
	return { cache = value }
end

local function pushCleanup(node: Node, cleanup: () -> ())
	if node.cleanups then
		table.insert(node.cleanups, cleanup)
	else
		node.cleanups = { cleanup }
	end
end

local function flushCleanups(node: Node)
	local cleanups = node.cleanups
	if not cleanups then
		return
	end
	node.cleanups = false
	for _, fn in cleanups do
		local ok, err = try(fn)
		if not ok then
			Graph.onError(`cleanup error: {err}`)
		end
	end
end

local function swapPop<T>(list: { T }, value: T)
	local index = table.find(list, value)
	if index == nil then
		return
	end
	local last = #list
	list[index] = list[last]
	list[last] = nil
end

local function unparent(node: Node)
	local parents = node.parents
	for index, parent in parents do
		swapPop(parent :: any, node)
		parents[index] = nil
	end
end

local function destroyOwned(node: Node)
	local owned = node.owned
	if owned then
		while owned[1] do
			Graph.destroy(owned[1])
		end
	end
end

function Graph.destroy(node: Node)
	flushCleanups(node)
	unparent(node)
	local owner = node.owner
	if owner then
		swapPop(owner.owned :: { Node }, node)
		node.owner = false
	end
	destroyOwned(node)
end

--[[
	Run a node's effect and store what it returns. True when the value moved,
	which is what decides whether anything downstream needs to run.

	Raises if the effect does. Creation sites let that through; the update
	queue catches it.
]]
local function evaluate(node: Node): boolean
	local previous = node.cache
	flushCleanups(node)
	destroyOwned(node)
	local ok, value = guarded(node, node.effect :: (any) -> any, previous)
	if not ok then
		error(value, 0)
	end
	node.cache = value
	return previous ~= value
end

local queue: { [number]: Node | false, n: number } = { n = 0 }
local batching = false

local function queueChildren(source: SourceNode)
	local n = queue.n
	while source[1] do
		n += 1
		queue[n] = source[1]
		unparent(source[1])
	end
	queue.n = n
end

local function flushQueue(from: number)
	local index = from + 1
	while index <= queue.n do
		local node = queue[index]
		-- A node queued and then destroyed has no owner; skip it.
		if node and node.owner then
			local ok, changed = pcall(evaluate, node)
			if not ok then
				Graph.onError(`effect error: {changed}`)
				-- The nearest boundary above, if there is one, swaps the
				-- broken part of the page for its fallback.
				local scope: Node | false = node.owner
				while scope do
					if scope.catch then
						pcall(scope.catch, tostring(changed))
						break
					end
					scope = scope.owner
				end
			elseif changed then
				queueChildren(node :: any)
			end
		end
		queue[index] = false
		index += 1
	end
	queue.n = from
end

local function updateDescendants(source: SourceNode)
	local from = queue.n
	queueChildren(source)
	if batching then
		return
	end
	flushQueue(from)
end

-- Subscribe the scope that is reading to `source`. Only reactive scopes
-- subscribe; a read from a component body is a plain read.
local function track(source: SourceNode)
	local scope = getScope()
	if scope and scope.effect then
		table.insert(source, scope)
		table.insert(scope.parents, source)
	end
end

local function requireScope(what: string): Node
	local scope = getScope()
	if scope == nil then
		error(`cannot use {what}() outside a scope: call it inside a page, a component, or root()`, 0)
	end
	return scope :: Node
end

--[[
	Hold updates until `fn` returns, then run each affected effect once.
	Nested calls join the outermost batch.
]]
function Graph.batch(fn: () -> ())
	if batching then
		fn()
		return
	end
	batching = true
	local from = queue.n
	local ok, err = guarded(getScope(), fn :: any, nil)
	batching = false
	flushQueue(from)
	if not ok then
		error(`error while batching updates:\n{err}`, 0)
	end
end

-- False while the calling code is inside an effect, a derive or a reactive
-- property or child, where waiting is not allowed.
function Graph.canYield(): boolean
	return reactive[coroutine.running()] ~= true
end

-- The live page that owns `scope`, if any.
function Graph.mountOf(scope: Node?): any?
	local current: Node | false = scope or false
	while current do
		if current.mount ~= nil then
			return current.mount
		end
		current = current.owner
	end
	return nil
end

Graph.getScope = getScope
Graph.pushScope = pushScope
Graph.popScope = popScope
Graph.requireScope = requireScope
Graph.createNode = createNode
Graph.createSourceNode = createSourceNode
Graph.pushCleanup = pushCleanup
Graph.evaluate = evaluate
Graph.track = track
Graph.updateDescendants = updateDescendants
Graph.traceback = traceback
Graph.try = try

return Graph
