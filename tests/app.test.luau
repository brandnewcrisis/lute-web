local task = require("@lute/task")
local web = require("@web")
local Live = require("@web/live")
local T = require("./check")
local check, eq = T.check, T.eq

local create, source = web.create, web.source

local function request(method: string, path: string, headers: { [string]: string }?): any
	return { method = method, path = path, body = "", query = {}, headers = headers or {} }
end

local function main()
	local hits = source(0)
	local blocked = false
	local app = web.app({
		before = function(req)
			if blocked and req.path ~= "/login" then
				return web.Response.redirect("/login")
			end
			return nil
		end,
	})

	app.page("/plain", function()
		return create "p" { "nothing moves here" }
	end)
	app.page("/live", function()
		return create "p" { "hits: ", hits }
	end)
	-- Built once and reused by every request, the way a layout usually is.
	local sharedHead = create "head" { create "title" { "S" } }
	app.page("/full", function()
		return create "html" { lang = "en", create "head" { create "title" { "Full" } }, create "body" { create "p" { hits } } }
	end)
	app.page("/shared-layout", function()
		return create "html" { sharedHead, create "body" { create "p" { hits } } }
	end)
	app.page("/gone", function()
		return web.Response.text("no such player", 404)
	end)
	app.page("/players/:id", function(req)
		return create "p" { "player ", req.params.id, " ", hits }
	end)
	app.page("/slow", function()
		task.wait(0.02)
		return create "p" { hits }
	end)
	app.page("/forced", function()
		return create "p" { "static but kept" }
	end, { live = true })
	app.get("/api", function()
		return web.Response.json({ ok = true })
	end)
	app.post("/api", function()
		return web.Response.text("posted")
	end)

	-- a page with nothing reactive is plain HTML and costs nothing to keep
	local before = Live.count()
	local plain = app.handle(request("GET", "/plain"))
	eq("static page status", plain.status, 200)
	check("static page is a whole document", plain.body:find("^<!doctype html><html lang=\"en\"><head>") ~= nil, plain.body)
	check("static page has no client script", plain.body:find("<script") == nil)
	eq("static page keeps no scope", Live.count(), before)

	-- a page with something reactive is kept and gets the client
	local live = app.handle(request("GET", "/live"))
	local id = live.body:match('data%-live="([%w_%-]+)"')
	check("live page carries its id", id ~= nil, live.body)
	check("live page loads the client from this origin", live.body:find('<script data%-live="[^"]+" data%-ws="/_live/ws" defer src="/_live/client.js%?v=%x+"></script></head>') ~= nil, live.body)
	check("live page is registered", id ~= nil and Live.find(id) ~= nil)
	check("live page shows current state", live.body:find("hits: <!%-%-%[1%-%->0") ~= nil)
	eq("live page is never cached", live.headers["cache-control"], "no-store")

	-- a page that returns <html> is used as it is
	local full = app.handle(request("GET", "/full"))
	check("own document is kept", full.body:find('^<!doctype html><html lang="en"><head><title>Full</title><script') ~= nil, full.body)
	eq("one script only", select(2, full.body:gsub("<script", "")), 1)

	-- adding the script must not write into nodes the page may share
	app.handle(request("GET", "/shared-layout"))
	local second = app.handle(request("GET", "/shared-layout"))
	eq("script is not accumulated across requests", select(2, second.body:gsub("<script", "")), 1)
	eq("the shared node itself is untouched", web.render(sharedHead), "<head><title>S</title></head>")

	-- a page may answer with a response instead
	local gone = app.handle(request("GET", "/gone"))
	check("page can return a response", gone.status == 404 and gone.body == "no such player")

	-- params, and a page function that waits
	local player = app.handle(request("GET", "/players/42"))
	check("page receives route params", player.body:find("player 42 ") ~= nil, player.body)
	local slow = app.handle(request("GET", "/slow"))
	check("page function may yield", slow.status == 200 and slow.body:find("data%-live") ~= nil)

	local forced = app.handle(request("GET", "/forced"))
	check("live = true keeps a page with nothing reactive", forced.body:find("data%-live") ~= nil)

	-- plain routes
	eq("get route", app.handle(request("GET", "/api")).body:gsub("%s", ""), '{"ok":true}')
	eq("post route", app.handle(request("POST", "/api")).body, "posted")
	eq("wrong method is 405", app.handle(request("DELETE", "/api")).status, 405)
	eq("unknown path is 404", app.handle(request("GET", "/nope")).status, 404)
	eq("query string does not affect matching", app.handle(request("GET", "/api?x=1")).status, 200)

	-- the client script
	local client = app.handle(request("GET", "/_live/client.js"))
	check("client script is served", client.status == 200 and client.headers["content-type"]:find("javascript") ~= nil)
	check("client script is cacheable", client.headers["cache-control"]:find("immutable") ~= nil)
	check("client script is the client", client.body:find("WebSocket", 1, true) ~= nil)

	-- before runs for pages too
	blocked = true
	local stopped = app.handle(request("GET", "/live"))
	check("before can short-circuit a page", stopped.status == 303 and stopped.headers.location == "/login")
	blocked = false

	-- security headers on everything
	check("csp on pages", live.headers["content-security-policy"]:find("default%-src 'self'") ~= nil)
end

local ok, err = xpcall(main, debug.traceback)
Live.reset()
if not ok then
	check("suite ran to the end", false, err)
end

T.done()
