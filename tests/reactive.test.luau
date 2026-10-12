local task = require("@lute/task")
local Reactive = require("@web/reactive")
local Graph = require("@web/graph")
local T = require("./check")
local check, eq, raises = T.check, T.eq, T.raises

local source, derive, effect, root = Reactive.source, Reactive.derive, Reactive.effect, Reactive.root
local cleanup, untrack, batch, context = Reactive.cleanup, Reactive.untrack, Reactive.batch, Reactive.context

local reported = {}
Graph.onError = function(message) table.insert(reported, message) end

-- sources
local count = source(1)
eq("source reads", count(), 1)
eq("source write returns the value", count(2), 2)
eq("source holds the write", count(), 2)

-- effects follow what they read
local runs, seen = 0, nil
local destroy = root(function()
	effect(function()
		runs += 1
		seen = count()
	end)
end)
eq("effect runs once on creation", runs, 1)
count(3)
eq("effect reruns on write", runs, 2)
eq("effect saw the new value", seen, 3)
count(3)
eq("equal write does not rerun", runs, 2)
destroy()
count(4)
eq("destroyed effect is silent", runs, 2)

-- a table is always a change, so mutate-and-write-back works
local list = source({ 1 })
local listRuns = 0
local destroyList = root(function()
	effect(function() list(); listRuns += 1 end)
end)
table.insert(list(), 2)
list(list())
eq("writing the same table reruns", listRuns, 2)
local frozen = table.freeze({ 1 })
list(frozen); list(frozen)
eq("writing the same frozen table does not", listRuns, 3)
destroyList()

-- derive: recomputed on change, passed on only when different
local n = source(1)
local parityRuns, downstream = 0, 0
local destroyDerive = root(function()
	local parity = derive(function()
		parityRuns += 1
		return n() % 2
	end)
	effect(function() parity(); downstream += 1 end)
end)
n(3)
eq("derive recomputed", parityRuns, 2)
eq("unchanged derive stops there", downstream, 1)
n(4)
eq("changed derive carries on", downstream, 2)
destroyDerive()

-- effect receives its previous return value
local totals = {}
local step = source(1)
local destroyAcc = root(function()
	effect(function(sum: number)
		local nextSum = sum + step()
		table.insert(totals, nextSum)
		return nextSum
	end, 0)
end)
step(10)
eq("effect is handed its last result", table.concat(totals, ","), "1,11")
destroyAcc()

-- cleanup runs before a rerun and on destroy
local log = {}
local flag = source("a")
local destroyCleanup = root(function()
	effect(function()
		local value = flag()
		cleanup(function() table.insert(log, "clean " .. value) end)
	end)
end)
flag("b")
eq("cleanup before rerun", table.concat(log, ";"), "clean a")
destroyCleanup()
eq("cleanup on destroy", table.concat(log, ";"), "clean a;clean b")
local closed = false
root(function() cleanup({ close = function() closed = true end }) end)()
check("cleanup takes an object with close", closed)

-- untrack
local tracked, ignored = source(1), source(1)
local untrackRuns = 0
local destroyUntrack = root(function()
	effect(function()
		tracked()
		untrack(function() return ignored() end)
		untrackRuns += 1
	end)
end)
ignored(2)
eq("untracked read does not subscribe", untrackRuns, 1)
tracked(2)
eq("tracked read still does", untrackRuns, 2)
destroyUntrack()

-- batch: many writes, one rerun
local a, b = source(1), source(1)
local sumRuns, sum = 0, 0
local destroyBatch = root(function()
	effect(function() sum = a() + b(); sumRuns += 1 end)
end)
batch(function() a(10); b(20) end)
eq("batch reruns once", sumRuns, 2)
eq("batch applied both writes", sum, 30)
destroyBatch()

-- effects created inside an effect are owned by it
local outer, inner = source(1), source(1)
local innerRuns = 0
local destroyNested = root(function()
	effect(function()
		outer()
		effect(function() inner(); innerRuns += 1 end)
	end)
end)
outer(2)
eq("inner effect rebuilt with outer", innerRuns, 2)
inner(2)
eq("only the live inner effect runs", innerRuns, 3)
destroyNested()

-- context
local Theme = context("light")
local read1, read2, read3
root(function()
	read1 = Theme()
	Theme("dark", function()
		read2 = Theme()
		effect(function() read3 = Theme() end)
	end)
end)()
eq("context default", read1, "light")
eq("context provided", read2, "dark")
eq("context reaches effects below", read3, "dark")
raises("context with no default and no provider", function()
	local Bare = context()
	root(function() return Bare() end)
end, "no default")

-- scopes are required where ownership matters
raises("effect outside a scope", function() effect(function() end) end, "outside a scope")
raises("derive outside a scope", function() derive(function() return 1 end) end, "outside a scope")

-- an effect that raises on creation raises there
raises("first run error propagates", function()
	root(function() effect(function() error("boom") end) end)
end, "boom")

-- an effect that raises on a rerun is reported and does not stop the others
local trigger = source(0)
local survivor = 0
local destroyErr = root(function()
	effect(function() if trigger() == 1 then error("bad rerun") end end)
	effect(function() trigger(); survivor += 1 end)
end)
reported = {}
local okWrite = pcall(trigger, 1)
check("a failing rerun does not throw from the write", okWrite)
eq("the other subscriber still ran", survivor, 2)
check("the failure was reported", #reported == 1 and reported[1]:find("bad rerun") ~= nil, reported[1])
destroyErr()

-- reactive scopes may not yield
raises("yield inside an effect", function()
	root(function() effect(function() task.wait(0.01) end) end)
end, "yield")

-- a root body may, and keeps its scope across the wait
local afterWait = false
local destroyYield = root(function()
	task.wait(0.01)
	effect(function() afterWait = true end)
end)
check("root body can yield and still own effects", afterWait)
destroyYield()

-- scopes are per coroutine: one waiting root does not adopt another's effects
local shared = source(0)
local slowRuns, fastRuns = 0, 0
local destroySlow: () -> ()
local slowDone = false
task.spawn(function()
	destroySlow = root(function()
		task.wait(0.05)
		effect(function() shared(); slowRuns += 1 end)
	end)
	slowDone = true
end)
local destroyFast = root(function()
	effect(function() shared(); fastRuns += 1 end)
end)
destroyFast()
while not slowDone do task.wait(0.01) end
shared(1)
eq("the destroyed root's effect is gone", fastRuns, 1)
eq("the waiting root kept its own", slowRuns, 2)
destroySlow()

-- every
local ticks = 0
local stop = root(function() Reactive.every(0.01, function() ticks += 1 end) end)
task.wait(0.06)
stop()
local atStop = ticks
task.wait(0.04)
check("every ticked", atStop >= 2, atStop)
eq("every stops with its scope", ticks, atStop)

-- ------------------------------------------------------------ resource
local resource = Reactive.resource

-- in a root body the first load is waited for
local calls = {}
local id = source(1)
local data, status
local destroyResource = root(function()
	data, status = resource(id, function(key: number)
		table.insert(calls, key)
		task.wait(0.02)
		if key == 13 then error("unlucky") end
		return "player " .. key
	end)
end)
eq("first load is finished before the body carries on", data(), "player 1")
check("not loading after the first load", status.loading() == false)
eq("the first key is fetched exactly once", #calls, 1)

-- a new key loads in the background and keeps the old value meanwhile
id(2)
check("loading while the new key is fetched", status.loading() == true)
eq("old value is kept while loading", data(), "player 1")
task.wait(0.05)
eq("new value arrives", data(), "player 2")
check("loading clears", status.loading() == false)

-- only the newest load counts
id(3); id(4)
task.wait(0.06)
eq("a superseded load is dropped", data(), "player 4")

-- a failing fetch is exposed and logged, and the last good value stays
reported = {}
id(13)
task.wait(0.05)
check("error is exposed", (status.error() or ""):find("unlucky") ~= nil, status.error())
eq("last good value stays", data(), "player 4")
check("error is also reported", #reported == 1)
id(5)
task.wait(0.05)
check("a later success clears the error", status.error() == nil and data() == "player 5")

-- refetch and mutate
local before = #calls
status.refetch()
eq("refetch loads the same key again", #calls, before + 1)
status.mutate("by hand")
eq("mutate sets the value", data(), "by hand")

-- effects can follow all three
local seenLoading = {}
local destroyWatch = root(function()
	effect(function() table.insert(seenLoading, status.loading()) end)
end)
id(6)
task.wait(0.05)
eq("loading is a source", #seenLoading, 3)
destroyWatch()

-- destroyed before the answer: nothing is written
id(7)
destroyResource()
task.wait(0.05)
eq("a load that outlives its scope is ignored", data(), "player 6")

-- a falsy key waits; a fetcher alone loads once
local none = source(nil :: number?)
local later, laterStatus
local fetched = 0
local destroyLater = root(function()
	later, laterStatus = resource(none, function(key: number) fetched += 1; return key * 2 end)
end)
check("nothing is fetched for a nil key", fetched == 0 and later() == nil and not laterStatus.loading())
none(21)
eq("fetching starts when the key appears", later(), 42)
destroyLater()
local once
local destroyOnce = root(function()
	once = resource(function() return "loaded" end)
end)
eq("resource with only a fetcher", once(), "loaded")
destroyOnce()

-- created where waiting is not allowed, it loads in the background instead
local inner
local destroyInner = root(function()
	effect(function()
		inner = resource(function() task.wait(0.01); return "bg" end)
	end)
end)
check("no value yet when created inside an effect", inner() == nil)
task.wait(0.04)
eq("the background load lands", inner(), "bg")
destroyInner()

T.done()
