--!strict
--[[
	lute-web -- reactive, server-rendered pages for the Lute runtime, written
	the way Vide writes UI.

	    local web = require("@web")
	    local create, source = web.create, web.source

	    local count = source(0)

	    local app = web.app({ port = 8080 })
	    app.page("/", function()
	        return create "button" {
	            onclick = function() count(count() + 1) end,
	            function() return `clicked {count()} times` end,
	        }
	    end)
	    app.serve()

	That is the whole program. The handler runs on the server, the text
	updates in every open tab, and there is no client code to write.
]]
local Html = require("@web/html")
local Reactive = require("@web/reactive")
local Flow = require("@web/flow")
local Live = require("@web/live")
local Route = require("@web/route")
local App = require("@web/app")

local Web = {}

export type Node = Html.Node
export type Source<T> = Reactive.Source<T>
export type Context<T> = Reactive.Context<T>
export type Status = Reactive.Status
export type Params = Route.Params
export type Location = Live.Location
export type Event = Live.Event
export type Request = App.Request

-- elements
Web.create = Html.create
Web.raw = Html.raw
Web.fragment = Html.fragment
Web.escape = Html.escape

-- state
Web.source = Reactive.source
Web.derive = Reactive.derive
Web.effect = Reactive.effect
Web.cleanup = Reactive.cleanup
Web.untrack = Reactive.untrack
Web.read = Reactive.read
Web.batch = Reactive.batch
Web.context = Reactive.context
Web.root = Reactive.root
Web.every = Reactive.every
Web.resource = Reactive.resource

-- control flow
Web.show = Flow.show
Web.switch = Flow.switch
Web.indexes = Flow.indexes
Web.values = Flow.values
Web.boundary = Flow.boundary

-- routing
Web.route = Route.route
Web.link = Route.link
Web.location = Route.location

-- the page an event handler or component belongs to
Web.navigate = Live.navigate
Web.reload = Live.reload
Web.emit = Live.emit

--[[
	Render to a string, once, with nothing kept.

	Takes a node, a list of nodes, or a component function. Anything
	reactive in it is read a single time. For fragments, emails and tests.
]]
function Web.render(content: any): string
	if type(content) ~= "function" then
		return Html.render(content)
	end
	local destroy, markup = Reactive.root(function()
		return Html.render((content :: () -> any)())
	end)
	destroy()
	return markup
end

Web.app = App.new

-- the rest of the toolkit
Web.App = App
Web.Html = Html
Web.Live = Live
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

Web.VERSION = "2.0.0"

return Web
