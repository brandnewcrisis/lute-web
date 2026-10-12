local Reactive = require("@web/reactive")
local Flow = require("@web/flow")
local T = require("./check")
local check, eq, raises = T.check, T.eq, T.raises

local source, effect, root, cleanup = Reactive.source, Reactive.effect, Reactive.root, Reactive.cleanup
local show, switch, values, indexes = Flow.show, Flow.switch, Flow.values, Flow.indexes

-- switch
local tab = source("a")
local built, torn = {}, {}
local shown
local destroy = root(function()
	shown = switch(tab)({
		a = function() table.insert(built, "a"); cleanup(function() table.insert(torn, "a") end); return "A" end,
		b = function() table.insert(built, "b"); cleanup(function() table.insert(torn, "b") end); return "B" end,
	})
end)
eq("switch shows the matching entry", shown(), "A")
tab("b")
eq("switch follows the source", shown(), "B")
eq("switch destroyed the old entry", table.concat(torn), "a")
tab("zzz")
eq("switch shows nothing for an unknown key", shown(), nil)
tab("a")
eq("switch rebuilds on return", table.concat(built), "aba")
destroy()
eq("switch entry dies with its owner", table.concat(torn), "aba")

-- show
local user = source(nil :: any)
local builds = 0
local view
local destroyShow = root(function()
	view = show(user, function(present)
		builds += 1
		return function() return "hi " .. present().name end
	end, function() return "signed out" end)
end)
eq("show uses the fallback when falsy", view(), "signed out")
user({ name = "ann" })
eq("show builds the component when truthy", (view() :: any)(), "hi ann")
user({ name = "bob" })
eq("show keeps the component across truthy values", builds, 1)
eq("the component reads the new value", (view() :: any)(), "hi bob")
user(nil)
eq("show returns to the fallback", view(), "signed out")
destroyShow()

-- values: one scope per item, output in list order
local A, B, C = { name = "a" }, { name = "b" }, { name = "c" }
local list = source({ A, B })
local made, dropped = {}, {}
local out
local destroyValues = root(function()
	out = values(list, function(item, index)
		table.insert(made, item.name)
		cleanup(function() table.insert(dropped, item.name) end)
		return { item = item, index = index }
	end)
end)
local function names() local t = {} for _, o in out() do table.insert(t, o.item.name .. o.index()) end return table.concat(t, " ") end
eq("values builds each item", names(), "a1 b2")
list({ C, A, B })
eq("values keeps list order and updates indexes", names(), "c1 a2 b3")
eq("values built only the new item", table.concat(made), "abc")
list({ B, C })
eq("values after removal", names(), "b1 c2")
eq("values destroyed the removed item", table.concat(dropped), "a")
local outputs = 0
local destroyCount = root(function() effect(function() out(); outputs += 1 end) end)
list({ B, C })
eq("values with nothing moved puts nothing out", outputs, 1)
list({ C, B })
eq("values puts out a reorder", outputs, 2)
destroyCount()
destroyValues()
eq("values destroys everything with its owner", #dropped, 3)
raises("values rejects duplicates", function()
	root(function() values(source({ "x", "x" }), function(v) return v end) end)
end, "twice")

-- indexes: one scope per position
local scores = source({ 10, 20 })
local slots = 0
local rows
local destroyIndexes = root(function()
	rows = indexes(scores, function(score, index)
		slots += 1
		return function() return index .. "=" .. score() end
	end)
end)
local function line() local t = {} for _, r in rows() do table.insert(t, r()) end return table.concat(t, " ") end
eq("indexes builds each position", line(), "1=10 2=20")
scores({ 11, 20 })
eq("indexes updates in place", line(), "1=11 2=20")
eq("indexes did not rebuild", slots, 2)
scores({ 11, 20, 30 })
eq("indexes grows", line(), "1=11 2=20 3=30")
scores({ 5 })
eq("indexes shrinks", line(), "1=5")
scores({ 7, 7 })
eq("indexes allows repeated values", line(), "1=7 2=7")
destroyIndexes()

-- boundary
local Graph = require("@web/graph")
local boundary = Flow.boundary
local logged = {}
Graph.onError = function(message) table.insert(logged, message) end

-- a component that fails while being built
local guarded
local destroyBuild = root(function()
	guarded = boundary(function()
		error("cannot build")
	end, function(message)
		return "fallback: " .. (message:match("cannot build") or "?")
	end)
end)
eq("a build failure shows the fallback", guarded(), "fallback: cannot build")
check("and is logged", #logged == 1 and logged[1]:find("cannot build") ~= nil)
destroyBuild()

-- a component that fails later, in an effect, and can be retried
local fuse = source(false)
local cleanedUp = 0
local retryFn
local later
local sibling = 0
local destroyLater = root(function()
	later = boundary(function()
		cleanup(function() cleanedUp += 1 end)
		effect(function()
			if fuse() then error("blew up") end
		end)
		return "fine"
	end, function(message, retry)
		retryFn = retry
		return "broken"
	end)
	effect(function() fuse(); sibling += 1 end)
end)
eq("a working component is shown", later(), "fine")
logged = {}
fuse(true)
eq("a later failure switches to the fallback", later(), "broken")
eq("what the component made is destroyed", cleanedUp, 1)
eq("effects outside the boundary still ran", sibling, 2)
check("the failure is logged", #logged >= 1 and logged[1]:find("blew up") ~= nil)
retryFn()
eq("retry while still failing shows the fallback again", later(), "broken")
fuse(false)
retryFn()
eq("retry once fixed shows the component", later(), "fine")
destroyLater()

-- an inner boundary keeps the failure from the outer one
local outer
local destroyNested = root(function()
	outer = boundary(function()
		local inner = boundary(function() error("inner") end, function() return "inner fallback" end)
		return function() return "outer ok / " .. inner() end
	end, function() return "outer fallback" end)
end)
eq("the nearest boundary handles it", (outer() :: any)(), "outer ok / inner fallback")
destroyNested()

T.done()
