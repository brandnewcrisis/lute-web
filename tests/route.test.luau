local task = require("@lute/task")
local web = require("@web")
local Live = require("@web/live")
local Graph = require("@web/graph")
local Router = require("@web/router")
local Fake = require("./fake")
local T = require("./check")
local check, eq = T.check, T.eq

local create, source, route, link = web.create, web.source, web.route, web.link
local page = Fake.page

local reported = {}
Graph.onError = function(message) table.insert(reported, message) end

local function request(method: string, path: string): any
	return { method = method, path = path, body = "", query = {}, headers = {} }
end

-- What a batch of messages amounts to: its markup, and where it sent the browser.
local function digest(messages)
	local out = { html = "", url = nil, go = nil, reload = false, ack = nil }
	for _, message in messages do
		if message.t == "p" then
			for _, patch in message.p do
				out.html ..= (patch.h or "") .. (if patch.v ~= nil then tostring(patch.v) else "")
			end
		elseif message.t == "url" then
			out.url = message.u
		elseif message.t == "go" then
			out.go = message.u
		elseif message.t == "reload" then
			out.reload = true
		elseif message.t == "ack" then
			out.ack = message
		end
	end
	return out
end

local function main()
	-- ---------------------------------------------- the server's router
	local r = Router.new()
	local function named(name) return function() return name :: any end end
	r.get("/*", named("catch-all"))
	r.get("/login", named("login"))
	r.get("/files/*", named("files"))
	r.get("/files/:name/raw", named("raw"))
	local function resolved(path) local h, p = r.resolve("GET", path); return h and (h :: any)(), p end
	eq("an exact route wins over a wildcard added before it", (resolved("/login")), "login")
	eq("a wildcard takes what nothing else does", (resolved("/anything/at/all")), "catch-all")
	eq("a wildcard matches its own root", (resolved("/")), "catch-all")
	eq("an exact longer route wins inside a wildcard", (resolved("/files/a/raw")), "raw")
	local _, rest = resolved("/files/a/b/c")
	eq("the remainder is params['*']", rest["*"], "a/b/c")

	-- ------------------------------------------------- matching a route
	local function App()
		return create "main" {
			route {
				["/"] = function() return create "h1" { "home" } end,
				["/players"] = function() return create "h1" { "players" } end,
				["/players/:id"] = function(params)
					return create "h1" { "player ", function() return params().id end }
				end,
				["/files/*"] = function(params)
					return create "h1" { "file ", function() return params()["*"] end }
				end,
				["*"] = function() return create "h1" { "not found" } end,
			},
		}
	end
	local function at(path) local mount = Live.mount(App, { path = path, query = {}, url = path }); local html = web.render(mount.node); local status = mount.status; mount:destroy(); return html, status end

	check("root", (at("/")):find("<h1>home</h1>") ~= nil, (at("/")))
	check("static path", (at("/players")):find("<h1>players</h1>") ~= nil)
	check("param", (at("/players/42")):find("player <!%-%-%[%d+%-%->42") ~= nil, (at("/players/42")))
	check("a fixed segment beats a param whatever the table order", (at("/players")):find("player ") == nil)
	check("wildcard gets the rest", (at("/files/a/b.txt")):find("a/b.txt") ~= nil)
	local missing, status = at("/nope/nothing")
	check("'*' is shown when nothing fits", missing:find("not found") ~= nil)
	eq("and answers 404", status, 404)
	eq("a match answers 200", select(2, at("/players")), nil)
	eq("outside a page, route shows '/'", web.render(function() return App() end), "<main><h1>home</h1></main>")

	-- ------------------------------------------------------ navigating
	local builds = {}
	local layoutState
	local function Shell()
		layoutState = source("kept")
		return create "div" {
			create "nav" {
				link { href = "/", "Home" },
				link { href = "/players", class = "item", "Players" },
			},
			create "aside" { layoutState },
			route {
				["/"] = function() table.insert(builds, "home"); return create "h1" { "home" } end,
				["/players"] = function() table.insert(builds, "list"); return create "h1" { "players" } end,
				["/players/:id"] = function(params)
					table.insert(builds, "one")
					return create "h1" { "player ", function() return params().id end, " ", function() return web.location().query.tab or "-" end }
				end,
			},
		}
	end
	local mount, tab = page(Shell, "/")
	local first = web.render(mount.node)
	check("link marks the current page", first:find('<a href="/" data%-l="%d+" aria%-current="page">Home</a>') ~= nil, first)
	check("link keeps its own attributes", first:find('<a class="item" href="/players" data%-l="%d+">Players</a>') ~= nil, first)

	layoutState("changed")
	tab.take()
	tab.visit("/players")
	local moved = digest(tab.take())
	check("following a link swaps the routed part", moved.html:find("<h1>players</h1>") ~= nil, moved.html)
	eq("the browser is told its new URL", moved.url, "/players")
	check("and the move is acknowledged", moved.ack ~= nil and moved.ack.ok == true)
	check("active link follows", web.render(mount.node):find('href="/players" data%-l="%d+" aria%-current="page"') ~= nil, web.render(mount.node))
	check("the layout was not rebuilt", web.render(mount.node):find("changed") ~= nil)
	eq("location is updated", (web.Live.find(mount.id) :: any).location().path, "/players")

	tab.visit("/players/7?tab=bans")
	moved = digest(tab.take())
	check("params and query reach the component", moved.html:find("player <!%-%-%[%d+%-%->7") ~= nil and moved.html:find("bans") ~= nil, moved.html)
	check("a link is active for what lies beneath it", web.render(mount.node):find('href="/players" data%-l="%d+" aria%-current="true"') ~= nil)

	local before = #builds
	tab.visit("/players/8?tab=bans")
	moved = digest(tab.take())
	eq("same pattern, new params: the component is kept", #builds, before)
	eq("only the param is patched", moved.html, "8")
	tab.visit("/players/8?tab=notes")
	eq("a query change alone patches what read it", digest(tab.take()).html, "notes")

	-- back/forward: the browser is already there, so it is not told
	tab.visit("/", true)
	moved = digest(tab.take())
	check("back swaps the content", moved.html:find("<h1>home</h1>") ~= nil)
	eq("back sends no URL", moved.url, nil)

	-- navigate() from a handler moves in place too
	local navMount, navTab = page(function()
		return create "div" {
			create "button" { onclick = function() web.navigate("/b") end, "go" },
			create "button" { onclick = function() web.navigate("/b", { replace = true }) end, "replace" },
			create "button" { onclick = function() web.navigate("https://example.com/") end, "out" },
			route {
				["/a"] = function() return create "p" { "page a" } end,
				["/b"] = function() return create "p" { "page b" } end,
			},
		}
	end, "/a")
	local html = web.render(navMount.node)
	local ids = {}
	for id in html:gmatch('data%-on%-click="(%d+)"') do table.insert(ids, tonumber(id)) end
	navTab.fire(ids[1])
	local got = navTab.take()
	moved = digest(got)
	check("navigate() swaps in place", moved.html:find("page b") ~= nil and moved.url == "/b")
	navTab.visit("/a", true); navTab.take()
	navTab.fire(ids[2])
	local replaced
	for _, message in navTab.take() do if message.t == "url" then replaced = message end end
	check("navigate with replace says so", replaced ~= nil and replaced.r == true)
	navTab.fire(ids[3])
	eq("navigate() elsewhere is an ordinary navigation", digest(navTab.take()).go, "https://example.com/")

	-- hostile or foreign URLs are never routed
	for _, url in { "//evil.example/x", "https://evil.example/", "javascript:alert(1)", "/\\evil" } do
		navTab.visit(url)
		local out = digest(navTab.take())
		check(`"{url}" is not moved to in place`, out.url == nil and out.html == "")
	end

	-- --------------------------------------------- pages that wait to build
	local slowBuilt = 0
	local slowMount, slowTab = page(function()
		return create "div" {
			route {
				["/"] = function() return create "p" { "start" } end,
				["/slow"] = function()
					task.wait(0.05)
					slowBuilt += 1
					return create "p" { "slow page" }
				end,
				["/fast"] = function() return create "p" { "fast page" } end,
				["/data/:id"] = function(params)
					local row = web.resource(function() return params().id end, function(id)
						task.wait(0.02)
						return "row " .. id
					end)
					return create "p" { row }
				end,
				["/broken"] = function() error("page exploded") end,
			},
		}
	end, "/")
	slowTab.visit("/slow")
	moved = digest(slowTab.take())
	check("a page may wait while being built", moved.html:find("slow page") ~= nil and moved.url == "/slow")

	-- a second navigation overtakes one still building
	task.spawn(function() slowTab.visit("/slow") end)
	slowTab.visit("/")
	slowTab.take()
	task.spawn(function() slowTab.visit("/slow") end)
	slowTab.visit("/fast")
	task.wait(0.1)
	slowTab.take()
	check("the later navigation wins", web.render(slowMount.node):find("fast page") ~= nil, web.render(slowMount.node))

	slowTab.visit("/data/5")
	moved = digest(slowTab.take())
	check("a resource in a routed page has its first load in the swap", moved.html:find("row 5") ~= nil, moved.html)

	reported = {}
	slowTab.visit("/broken")
	moved = digest(slowTab.take())
	check("a page that fails to build leaves the old one up", web.render(slowMount.node):find("row 5") ~= nil)
	check("and the failure is reported and acknowledged as one", moved.ack.ok == false and #reported == 1 and moved.url == nil)

	-- ----------------------------------------------------------- nesting
	local sectionBuilds = 0
	local nestedMount, nestedTab = page(function()
		return create "div" {
			route {
				["/"] = function() return create "p" { "root" } end,
				["/admin/*"] = function()
					sectionBuilds += 1
					return create "section" {
						create "h2" { "admin" },
						route {
							["/admin"] = function() return create "p" { "overview" } end,
							["/admin/users/:id"] = function(params) return create "p" { "user ", function() return params().id end } end,
						},
					}
				end,
			},
		}
	end, "/admin")
	check("nested routes render", web.render(nestedMount.node):find("<h2>admin</h2>.*overview") ~= nil, web.render(nestedMount.node))
	nestedTab.visit("/admin/users/3")
	moved = digest(nestedTab.take())
	check("moving within a section swaps only the inner route", moved.html:find("user ") ~= nil and moved.html:find("admin</h2>") == nil, moved.html)
	eq("the section was not rebuilt", sectionBuilds, 1)
	nestedTab.visit("/")
	nestedTab.take()
	eq("leaving the section removes its router", #nestedMount.routers, 1)
	nestedTab.visit("/admin/users/9")
	check("and coming back builds it at the right place", digest(nestedTab.take()).html:find("user <!%-%-%[%d+%-%->9") ~= nil)

	-- ------------------------------------------------------ with an app
	local signedIn = true
	local app = web.app({
		before = function(req)
			if req.path:find("^/secret") and not signedIn then
				return web.Response.redirect("/login")
			end
			return nil
		end,
	})
	app.get("/login", function() return web.Response.text("login form") end)
	app.page("/*", function()
		return create "div" {
			route {
				["/"] = function() return create "p" { "home" } end,
				["/secret"] = function() return create "p" { "secret" } end,
				["*"] = function() return create "p" { "nothing here" } end,
			},
		}
	end)
	local home = app.handle(request("GET", "/"))
	check("a routed page tells the client to follow links", home.body:find("data%-routed") ~= nil, home.body)
	check("the page is built for the URL asked for", app.handle(request("GET", "/secret")).body:find("<p>secret</p>") ~= nil)
	local lost = app.handle(request("GET", "/no/such/page"))
	check("an unknown URL answers 404 with the not-found page", lost.status == 404 and lost.body:find("nothing here") ~= nil)
	eq("plain routes still win over the catch-all", app.handle(request("GET", "/login")).body, "login form")

	local appMount = Live.find(home.body:match('data%-live="([%w_%-]+)"') :: string) :: any
	local appTab = Fake.browser(appMount)
	appTab.hello()
	appTab.visit("/secret")
	check("a URL of the same page is moved to in place", digest(appTab.take()).url == "/secret")
	appTab.visit("/login")
	eq("a URL that is a different route is loaded the ordinary way", digest(appTab.take()).go, "/login")
	signedIn = false
	appTab.visit("/")
	appTab.take()
	appTab.visit("/secret")
	moved = digest(appTab.take())
	check("before is asked again on every move", moved.go == "/secret" and moved.html == "")
	appTab.visit("/login", true)
	check("a back press that cannot be handled in place reloads", digest(appTab.take()).reload)
end

local ok, err = xpcall(main, debug.traceback)
Live.reset()
if not ok then
	check("suite ran to the end", false, err)
end

T.done()
