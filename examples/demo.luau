--!strict
-- A small app showing what a live page is. Open it in two tabs.
--   lute run examples/demo.luau   ->  http://127.0.0.1:8123
local task = require("@lute/task")
local web = require("@web")
local create, source, derive = web.create, web.source, web.derive
local show, values, indexes = web.show, web.values, web.indexes
local route, link = web.route, web.link

type Todo = { text: string, done: web.Source<boolean> }

-- State made out here belongs to the server, so every visitor shares it:
-- a write from one tab shows up in all of them.
local todos = source({
	{ text = "Open this page in a second tab", done = source(false) },
	{ text = "Tick this one from either", done = source(false) },
} :: { Todo })
local online = source(0)
local now = source(os.date("!%H:%M:%S") :: string)

local function Header()
	return create "header" {
		create "h1" { "lute-web" },
		create "span" { class = "pill", function()
			return `{online()} online`
		end },
		create "span" { class = "pill dim", now, " UTC" },
	}
end

local function TodoRow(todo: Todo)
	return create "li" {
		class = function()
			return if todo.done() then "done" else nil
		end,
		create "button" {
			class = "tick", type = "button",
			onclick = function()
				todo.done(not todo.done())
			end,
			function()
				return if todo.done() then "☑" else "☐"
			end,
		},
		-- Typed by a visitor, so escaped: a todo named <img onerror=...> is
		-- shown, never run.
		create "span" { class = "text", todo.text },
		create "button" {
			class = "del", type = "button",
			["data-confirm"] = `Delete "{todo.text}"?`,
			onclick = function()
				local list = todos()
				table.remove(list, table.find(list, todo) :: number)
				todos(list)
			end,
			"×",
		},
	}
end

local function Todos()
	-- State made in here belongs to this one tab. Two tabs can look at the
	-- same list through different filters.
	local filter = source("all")
	local problem = source(nil :: string?)

	local visible = derive(function()
		local out = {}
		for _, todo in todos() do
			if filter() == "all" or (filter() == "open") == not todo.done() then
				table.insert(out, todo)
			end
		end
		return out
	end)

	local function tab(name: string)
		return create "button" {
			type = "button",
			class = function() return if filter() == name then "tab on" else "tab" end,
			onclick = function() filter(name) end,
			name,
		}
	end

	return create "section" {
		create "form" {
			["data-reset"] = true,
			onsubmit = function(event: web.Event)
				local form = event.form
				local text = (if form then form.text or "" else ""):gsub("^%s+", ""):gsub("%s+$", "")
				if text == "" then
					problem("type something first")
					return
				end
				problem(nil)
				local list = todos()
				table.insert(list, { text = text, done = source(false) })
				todos(list)
			end,
			create "input" { name = "text", placeholder = "add a task", autocomplete = "off" },
			create "button" { type = "submit", "add" },
		},
		show(problem, function(message)
			return create "p" { class = "err", message }
		end),
		create "nav" { tab("all"), tab("open"), tab("done") },
		create "ul" {
			values(visible, TodoRow),
			show(function() return #visible() == 0 end, function()
				return create "li" { class = "empty", "nothing here" }
			end),
		},
	}
end

local function Echo()
	local text = source("")
	local lines = source({} :: { string })
	return create "section" {
		create "h2" { "Per-tab state" },
		create "form" {
			-- Cleared in the browser the moment it is sent, so whatever is
			-- typed next starts in an empty box however slow the network.
			["data-reset"] = true,
			onsubmit = function(event: web.Event)
				local form = event.form
				local list = lines()
				table.insert(list, if form then form.line or "" else "")
				lines(list)
				text("")
			end,
			create "input" {
				name = "line",
				placeholder = "type, then press Enter",
				autocomplete = "off",
				oninput = function(event: web.Event) text(event.value or "") end,
			},
		},
		create "p" { class = "dim", function()
			return if text() == "" then "The server will shout it back." else text():upper()
		end },
		create "ol" { indexes(lines, function(line)
			return create "li" { line }
		end) },
	}
end

local API = {
	"source", "derive", "effect", "cleanup", "untrack", "batch", "context", "root", "read",
	"show", "switch", "values", "indexes", "boundary", "resource", "every",
	"create", "raw", "render", "navigate", "reload", "emit",
}

local function Search()
	local query = source("")
	-- Effects cannot wait, so slow things go through a resource: it reloads
	-- whenever `query` changes and keeps the old answer on screen meanwhile.
	local matches, status = web.resource(query, function(text: string)
		task.wait(0.4) -- stands in for a database
		local out = {}
		for _, name in API do
			if name:find(text:lower(), 1, true) then
				table.insert(out, name)
			end
		end
		return out
	end)

	return create "section" {
		create "h2" { "Waiting for data" },
		create "input" {
			placeholder = "search the API",
			autocomplete = "off",
			oninput = function(event: web.Event) query(event.value or "") end,
		},
		create "p" {
			class = "dim",
			function()
				return if status.loading() then "searching…" else `{#(matches() or {})} found`
			end,
		},
		create "ul" {
			class = function() return if status.loading() then "tags stale" else "tags" end,
			indexes(function() return matches() or {} end, function(name)
				return create "li" { name }
			end),
		},
	}
end

local function Fragile()
	local broken = source(false)
	return create "section" {
		create "h2" { "Containing a failure" },
		-- Without the boundary this error would be logged and the card left
		-- showing stale text. With it, the card is swapped for the fallback
		-- and the rest of the page never notices.
		web.boundary(function()
			return create "p" {
				function()
					if broken() then
						error("this card is broken")
					end
					return "This card is fine. "
				end,
				create "button" { type = "button", onclick = function() broken(true) end, "break it" },
			}
		end, function(_message, retry)
			return create "p" {
				class = "err",
				"The card failed. ",
				create "button" {
					type = "button",
					onclick = function()
						broken(false)
						retry()
					end,
					"try again",
				},
			}
		end),
	}
end

local function NotFound()
	return create "section" {
		create "h2" { "Nothing here" },
		create "p" { class = "dim", "No page lives at ", function() return web.location().path end, "." },
	}
end

local function App()
	-- Count this tab for as long as it stays open.
	online(online() + 1)
	web.cleanup(function()
		online(online() - 1)
	end)

	return create "html" {
		lang = "en",
		create "head" {
			create "meta" { charset = "utf-8" },
			create "meta" { name = "viewport", content = "width=device-width, initial-scale=1" },
			create "title" { function()
				local open = 0
				for _, todo in todos() do
					if not todo.done() then open += 1 end
				end
				return `({open}) lute-web demo`
			end },
			create "link" { rel = "stylesheet", href = "/static/demo.css" },
		},
		create "body" {
			Header(),
			-- Ordinary links. On a page with routes they are followed
			-- without loading a new document, so the header above keeps
			-- its scope and only what is inside `route` is swapped.
			create "nav" {
				class = "views",
				link { href = "/", "todos" },
				link { href = "/echo", "echo" },
				link { href = "/search", "search" },
				link { href = "/errors", "errors" },
			},
			route {
				["/"] = Todos,
				["/echo"] = Echo,
				["/search"] = Search,
				["/errors"] = Fragile,
				["*"] = NotFound,
			},
			create "footer" { class = "dim", "connection: ", create "span" { class = "conn" } },
		},
	}
end

local app = web.app({ port = 8123, staticDir = "./public" })

-- One clock for everybody. It lives in a root of its own, not in a page,
-- so it ticks whether or not anyone is looking.
web.root(function()
	web.every(1, function()
		now(os.date("!%H:%M:%S") :: string)
	end)
end)

app.page("/*", App)
app.serve()
