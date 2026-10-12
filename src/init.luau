--!strict
--[[
	lute-web -- a small web toolkit for the Lute Luau runtime, built for htmx.

	    local web = require("@web")
	    local h, hx = web.html, web.htmx

	    local app = web.App.new({ port = 8080, staticDir = "./public" })
	    app.get("/", function(req)
	        return hx.page(req, layout, h.div({ id = "clock" }, os.date()))
	    end)
	    app.serve()

	The pieces are usable on their own -- `html` and `router` have no
	dependency on `App` -- so this can be adopted a module at a time.
]]
local Web = {}

Web.html = require("@web/html")
Web.htmx = require("@web/htmx")
Web.App = require("@web/app")
Web.Router = require("@web/router")
Web.Response = require("@web/response")
Web.Cookies = require("@web/cookies")
Web.Session = require("@web/session")
Web.Static = require("@web/static")
Web.Form = require("@web/form")
Web.Json = require("@web/json")
Web.Bytes = require("@web/bytes")
Web.Hmac = require("@web/hmac")
Web.Log = require("@web/log")

Web.VERSION = "0.1.0"

return Web
