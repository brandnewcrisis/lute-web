--!strict
-- A small app exercising the parts of lute-web that are easy to get wrong:
-- one handler serving both full pages and fragments, a form post, an
-- out-of-band swap, and a polling fragment.
--   lute run examples/demo.luau   ->  http://127.0.0.1:8123
local web = require("@web")
local h, hx = web.html, web.htmx

local todos: { { id: number, text: string, done: boolean } } = {
	{ id = 1, text = "Wire up the panel", done = true },
	{ id = 2, text = "Verify a Roblox account", done = false },
}
local nextId = 3

local function counter(): h.Node
	local open = 0
	for _, t in todos do
		if not t.done then open += 1
	end end
	return h.span({ id = "count", class = "count" }, `{open} open`)
end

local function row(todo: any): h.Node
	return h.li({ class = if todo.done then "done" else "" },
		h.button(hx.attrs({
			post = `/toggle/{todo.id}`,
			target = "#list",
			swap = "outerHTML",
			class = "tick",
		}), if todo.done then "☑" else "☐"),
		-- User text, escaped by default: a todo named <img onerror=...> is
		-- rendered, never executed.
		h.span({ class = "text" }, todo.text),
		h.button(hx.attrs({
			delete = `/todo/{todo.id}`,
			target = "#list",
			swap = "outerHTML",
			confirm = `Delete "{todo.text}"?`,
			class = "del",
		}), "×")
	)
end

--[[
	The list, optionally with an out-of-band counter attached.

	`withOob` matters: an out-of-band node belongs ONLY in a response htmx is
	swapping. On a full page load the shell already renders the counter, so
	including it here draws a second one loose in the document -- which is
	exactly what happened the first time this demo was rendered in a browser.
]]
local function list(withOob: boolean?): h.Node
	local items = {}
	for _, todo in todos do
		table.insert(items, row(todo))
	end
	local ul = h.ul({ id = "list" }, #items > 0 and items or h.li({ class = "empty" }, "nothing left"))
	if not withOob then
		return ul
	end
	-- One response updates the list AND the header badge, no second request.
	return h.fragment({ ul, hx.oob(counter()) })
end

local function shell(inner: any): h.Node
	return h.html({ lang = "en" },
		h.head({},
			h.meta({ charset = "utf-8" }),
			h.title({}, "lute-web demo"),
			h.script({ src = "/static/htmx.min.js", defer = true }),
			h.link({ rel = "stylesheet", href = "/static/demo.css" })
		),
		h.body({},
			h.h1({}, "lute-web ", counter()),
			h.form(hx.attrs({ post = "/add", target = "#list", swap = "outerHTML" }),
				h.input({ name = "text", placeholder = "add a task", autocomplete = "off" }),
				h.button({ type = "submit" }, "add")
			),
			inner,
			h.p({ class = "hint" }, "clock polls every second: ",
				h.span(hx.attrs({ get = "/clock", trigger = "every 1s", swap = "innerHTML" }), "--"))
		)
	)
end

local app = web.App.new({ port = 8123, staticDir = "./public" })

app.get("/", function(request)
	-- Same handler answers a whole document or just the list. The fragment
	-- form carries the OOB counter; the full page does not need it.
	return hx.page(request, shell, list(hx.isRequest(request) and not hx.isBoosted(request)))
end)

app.get("/clock", function()
	return web.Response.html(h.span({}, os.date("!%H:%M:%S") :: string))
end)

app.post("/add", function(request)
	local text = web.Form.parse(request.body).text or ""
	if text:gsub("%s", "") == "" then
		-- Send the complaint to the header instead of replacing the list.
		return hx.retarget(web.Response.html(h.span({ class = "err" }, "type something first")), "#count")
	end
	table.insert(todos, { id = nextId, text = text, done = false })
	nextId += 1
	return web.Response.html(list(true))
end)

app.post("/toggle/:id", function(request)
	local id = tonumber(request.params.id)
	for _, todo in todos do
		if todo.id == id then
			todo.done = not todo.done
		end
	end
	return web.Response.html(list(true))
end)

app.delete("/todo/:id", function(request)
	local id = tonumber(request.params.id)
	for index, todo in todos do
		if todo.id == id then
			table.remove(todos, index)
			break
		end
	end
	return web.Response.html(list(true))
end)

app.serve()
