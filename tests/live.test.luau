local task = require("@lute/task")
local web = require("@web")
local Live = require("@web/live")
local Graph = require("@web/graph")
local T = require("./check")
local check, eq, raises = T.check, T.eq, T.raises

local source, show, values, indexes = web.source, web.show, web.values, web.indexes
local create = web.create

local reported = {}
Graph.onError = function(message) table.insert(reported, message) end

local Fake = require("./fake")
local browser, page = Fake.browser, Fake.page

-- Registered pages keep the process alive, so whatever happens the suite
-- has to end by letting go of them.
local function main()
-- ---------------------------------------------------------- first render
local count = source(0)
local mount, tab = page(function()
	return create "div" {
		create "p" { "count: ", count },
		create "b" { class = function() return if count() > 0 then "on" else nil end, "x" },
	}
end)
eq("regions are marked, addressed elements carry an id", web.render(mount.node),
	'<div><p>count: <!--[1-->0<!--]1--></p><b data-l="2">x</b></div>')
eq("a connected page with nothing changed is sent nothing", #tab.take(), 0)

-- ------------------------------------------------------------- patches
count(1)
local patches = tab.patches()
eq("one patch per binding", #patches, 2)
eq("region patch carries the new markup", patches[1].r == 1 and patches[1].h, "1")
check("attribute patch names the element", patches[2].a == 2 and patches[2].n == "class" and patches[2].v == "on")
eq("the tree renders current state", web.render(mount.node),
	'<div><p>count: <!--[1-->1<!--]1--></p><b data-l="2" class="on">x</b></div>')

count(2); count(3); count(4)
patches = tab.patches()
eq("several writes before a flush send the last value once", #patches, 1)
eq("...and it is the last value", patches[1].h, "4")

count(0)
patches = tab.patches()
check("a nil attribute is sent as a removal", patches[2].a == 2 and patches[2].n == "class" and patches[2].v == nil)

-- An effect that reran to the same output is not sent.
local parity = source(0)
local _, parityTab = page(function()
	return create "p" { function() return if parity() % 2 == 0 then "even" else "odd" end }
end)
parity(2)
eq("unchanged output sends nothing", #parityTab.patches(), 0)
parity(3)
eq("changed output sends", #parityTab.patches(), 1)

mount:destroy()
count(9)
eq("a destroyed page stops following its sources", #tab.take(), 0)

-- -------------------------------------------------------------- escaping
local name = source("ann")
local _, nameTab = page(function() return create "p" { name } end)
name("<img src=x onerror=alert(1)>")
eq("patched text is escaped", nameTab.patches()[1].h, "&lt;img src=x onerror=alert(1)&gt;")
local link = source("/ok")
local _, linkTab = page(function() return create "a" { href = link, "go" } end)
link("javascript:alert(1)")
eq("patched URLs are checked", linkTab.patches()[1].v, "#")

-- ------------------------------------------------------- text-only elements
local unread = source(2)
local titleMount, titleTab = page(function()
	return create "html" { create "head" { create "title" { "Inbox (", unread, ")" } }, create "body" { "x" } }
end)
check("a reactive title binds the element, with no markers", titleMount:html():find('<title data%-l="1">Inbox %(2%)</title>') ~= nil, titleMount:html())
unread(3)
local titlePatch = titleTab.patches()[1]
check("title change is a text patch", titlePatch.x == 1 and titlePatch.v == "Inbox (3)")

-- ---------------------------------------------------------------- events
local clicks = source(0)
local lastEvent
local eventMount, eventTab = page(function()
	return create "div" {
		create "button" { onclick = function() clicks(clicks() + 1) end, "inc" },
		create "input" { oninput = function(event) lastEvent = event end },
		create "span" { clicks },
	}
end)
check("handlers render as data-on attributes", web.render(eventMount.node):find('<button data%-on%-click="1">') ~= nil, web.render(eventMount.node))
eventTab.fire(1, { type = "click" }, 7)
local got = eventTab.take()
eq("a handled event answers with a patch then an ack", #got, 2)
check("patch first", got[1].t == "p" and got[1].p[1].h == "1")
check("ack carries the event number", got[2].t == "ack" and got[2].n == 7 and got[2].ok == true)
eventTab.fire(2, { type = "input", value = "hey", name = "q", bogus = { 1 }, checked = "yes" })
check("event fields arrive", lastEvent.type == "input" and lastEvent.value == "hey" and lastEvent.name == "q")
check("unknown and mistyped fields are dropped", (lastEvent :: any).bogus == nil and lastEvent.checked == nil)
eventTab.take()
eventTab.fire(999, nil, 8)
got = eventTab.take()
check("an event for no handler is acknowledged and ignored", #got == 1 and got[1].t == "ack")

-- a handler that raises is reported, and the browser is told
local badMount, badTab = page(function()
	return create "button" { onclick = function() error("handler broke") end, "x" }
end)
reported = {}
badTab.fire(1, nil, 3)
got = badTab.take()
check("failed handler acks not ok", got[1].t == "ack" and got[1].ok == false and got[1].m == nil)
check("failed handler is reported", #reported == 1 and reported[1]:find("handler broke") ~= nil)
Live.debug = true
badTab.fire(1, nil, 4)
check("debug mode sends the message", (badTab.take()[1].m or ""):find("handler broke") ~= nil)
Live.debug = false
badMount:destroy()

-- handlers may wait
local slow = source("idle")
local _, slowTab = page(function()
	return create "div" { create "button" { onclick = function() task.wait(0.02); slow("done") end, "go" }, create "i" { slow } }
end)
slowTab.fire(1)
got = slowTab.take()
check("a waiting handler finished before its ack", got[1].t == "p" and got[1].p[1].h == "done" and got[2].t == "ack")

-- a handler belongs to the markup that made it
local which = source("a")
local hits = {}
local swapMount, swapTab = page(function()
	return create "div" { function()
		local now = which()
		return create "button" { onclick = function() table.insert(hits, now) end, now }
	end }
end)
local oldHandler = tonumber(web.render(swapMount.node):match('data%-on%-click="(%d+)"'))
which("b")
local newHandler = tonumber(swapTab.patches()[1].h:match('data%-on%-click="(%d+)"'))
check("rebuilt markup gets a new handler", oldHandler ~= newHandler)
swapTab.fire(oldHandler :: number); swapTab.fire(newHandler :: number)
eq("the replaced handler is gone, the new one runs", table.concat(hits), "b")

-- navigate / emit from a handler
local _, navTab = page(function()
	return create "button" { onclick = function() web.emit("saved", { id = 3 }); web.navigate("/next") end, "x" }
end)
navTab.fire(1)
got = navTab.take()
check("emit reaches the browser", got[1].t == "ev" and got[1].n == "saved" and got[1].d.id == 3)
check("navigate reaches the browser", got[2].t == "go" and got[2].u == "/next")
check("both before the ack", got[3].t == "ack")
raises("navigate outside a page", function() web.navigate("/x") end, "live page")

-- ------------------------------------------------------------- show
local open = source(false)
local showMount, showTab = page(function()
	local inner = source("first")
	return create "div" {
		create "button" { onclick = function() inner("second") end, "x" },
		show(open, function() return create "p" { inner } end),
	}
end)
check("hidden renders an empty region", web.render(showMount.node):find("<!%-%-%[%d+%-%-><!%-%-%]%d+%-%->") ~= nil)
open(true)
check("shown sends the component", showTab.patches()[1].h:find("^<p><!%-%-%[%d+%-%->first") ~= nil)
showTab.fire(1)
eq("a binding inside the shown part patches by itself", showTab.patches()[1].h, "second")
open(false)
eq("hiding empties the region", showTab.patches()[1].h, "")

-- ------------------------------------------------------------- lists
local A, B, C = { text = "a" }, { text = "b" }, { text = "c" }
local rows = source({ A, B })
local built = 0
local listMount, listTab = page(function()
	return create "ul" { values(rows, function(row, index)
		built += 1
		local done = source(false)
		row.toggle = function() done(not done()) end
		return create "li" { class = function() return if done() then "done" else nil end, index, " ", row.text }
	end) }
end)
local first = web.render(listMount.node)
local keyA = first:match('<li data%-key="(v%d+)"[^>]*><!%-%-%[%d+%-%->1')
check("list items are keyed", keyA ~= nil, first)
A.toggle()
listTab.take()
rows({ C, A, B })
local listPatch
for _, patch in listTab.patches() do
	if patch.h and patch.h:find("<li") then listPatch = patch.h end
end
eq("only the new row was built", built, 3)
check("a kept row keeps its key and its state", listPatch:find(`<li data%-key="{keyA}" data%-l="%d+" class="done">`) ~= nil, listPatch)
check("rows come out in list order", listPatch:find("c.*a.*b") ~= nil)
check("indexes inside kept rows are current", listPatch:find("%->2<!") ~= nil, listPatch)
local explicit = web.render(function() return create "ul" { values(source({ A }), function(row) return create "li" { key = "mine", row.text } end) } end)
eq("an explicit key is kept; outside a page none is added", explicit, '<ul><li data-key="mine">a</li></ul>')

local scores = source({ 1, 2 })
local _, scoreTab = page(function()
	return create "ol" { indexes(scores, function(score) return create "li" { score } end) }
end)
scores({ 1, 5 })
local scorePatches = scoreTab.patches()
check("indexes patches the one changed cell", #scorePatches == 1 and scorePatches[1].h == "5")

-- ------------------------------------------------ resource and boundary
local term = source("a")
local searchMount, searchTab = page(function()
	local results, status = web.resource(term, function(q)
		task.wait(0.02)
		if q == "bad" then error("search failed") end
		return { q .. "1", q .. "2" }
	end)
	return create "div" {
		class = function() return if status.loading() then "loading" else nil end,
		create "ul" { indexes(results :: any, function(item) return create "li" { item } end) },
	}
end)
check("the page is rendered with its first load in it", web.render(searchMount.node):find("<li><!%-%-%[%d+%-%->a1") ~= nil, web.render(searchMount.node))
term("b")
local during = searchTab.patches()
check("loading is patched in at once", #during == 1 and during[1].n == "class" and during[1].v == "loading")
task.wait(0.05)
local after = searchTab.patches()
local sawResults, sawIdle = false, false
for _, patch in after do
	sawResults = sawResults or (patch.h ~= nil and patch.h:find("b1") ~= nil)
	sawIdle = sawIdle or (patch.n == "class" and patch.v == nil)
end
check("results and the end of loading arrive when the fetch does", sawResults and sawIdle)

local trip = source(false)
local _, guardTab = page(function()
	return create "div" {
		web.boundary(function()
			return create "p" { function()
				if trip() then error("card broke") end
				return "card"
			end }
		end, function(_message, retry)
			return create "button" { onclick = retry, "try again" }
		end),
		create "footer" { "still here ", function() return tostring(trip()) end },
	}
end)
reported = {}
trip(true)
local guardPatches = guardTab.patches()
local sawFallback, sawFooter = false, false
for _, patch in guardPatches do
	sawFallback = sawFallback or (patch.h ~= nil and patch.h:find("try again") ~= nil)
	sawFooter = sawFooter or patch.h == "true"
end
check("a failing card is replaced by its fallback", sawFallback)
check("the rest of the page keeps updating", sawFooter)
trip(false)
guardTab.take()
local retryId = nil
for _, patch in guardPatches do
	retryId = retryId or (patch.h and tonumber(patch.h:match('data%-on%-click="(%d+)"')))
end
guardTab.fire(retryId :: number)
local retried = false
for _, message in guardTab.take() do
	if message.t == "p" then
		for _, patch in message.p do
			retried = retried or (patch.h ~= nil and patch.h:find("<p>") ~= nil and patch.h:find("card") ~= nil)
		end
	end
end
check("retry from the browser brings the card back", retried)

-- ------------------------------------------------- disconnect and resync
local flaky = source("one")
local flakyMount, flakyTab = page(function() return create "html" { create "body" { create "p" { flaky } } } end)
flaky("two")
flakyTab.take()
Live.closed(flakyTab.connection)
check("a closed socket leaves the page waiting", Live.find(flakyMount.id) == flakyMount)
flaky("three"); flaky("two")
eq("nothing is sent to a closed socket", #flakyTab.take(), 0)
local again = browser(flakyMount)
again.hello()
got = again.take()
check("reconnecting sends the whole page as it stands", #got == 1 and got[1].t == "sync" and got[1].h:find("two") ~= nil, got[1] and got[1].h)
flaky("three")
eq("and patches resume", again.patches()[1].h, "three")
flaky("two")
eq("a value last sent before the gap is sent again after it", again.patches()[1].h, "two")

-- the same page opened twice: the newer connection wins
local third = browser(flakyMount)
third.hello()
check("the older connection is told to start over", again.take()[1].t == "gone")
check("the newer one is brought up to date", third.take()[1].t == "sync")
flaky("four")
eq("only the newer one is patched", #again.take(), 0)

-- ----------------------------------------------------------- lifecycle
local stranger = browser(flakyMount)
stranger.say({ t = "hello", m = "not-a-real-page" })
eq("an unknown page id is told it is gone", stranger.take()[1].t, "gone")
stranger.fire(1)
eq("and nothing else it says is acted on", #stranger.take(), 0)
stranger.connection.send = function() error("should not be called") end
Live.receive(stranger.connection, "not json")
Live.receive(stranger.connection, "[1,2]")
check("junk is ignored", true)

local cleaned = false
local byeMount, byeTab = page(function()
	web.cleanup(function() cleaned = true end)
	return create "p" { flaky }
end)
byeTab.say({ t = "bye" })
check("bye destroys the page", Live.find(byeMount.id) == nil and cleaned)

-- a page nobody connects to is dropped
Live.connectWithin = 0.05
local orphan = Live.mount(function() return create "p" { flaky } end)
Live.register(orphan)
task.wait(1.3)
check("an unconnected page expires", Live.find(orphan.id) == nil)
Live.connectWithin = 15

-- a ceiling on unattached pages
Live.reset()
Live.maxMounts = 3
local made = {}
for index = 1, 5 do
	made[index] = Live.mount(function() return create "p" { flaky } end)
	Live.register(made[index])
end
check("pages past the limit push out the oldest unattached", Live.count() <= 4 and Live.find(made[1].id) == nil, Live.count())
Live.maxMounts = 5000

Live.reset()
eq("reset leaves nothing", Live.count(), 0)

end

local ok, err = xpcall(main, debug.traceback)
Live.reset()
if not ok then
	check("suite ran to the end", false, err)
end
T.done()
