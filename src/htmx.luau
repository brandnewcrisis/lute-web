--!strict
--[[
	htmx support: reading what htmx sent, and telling it what to do next.

	htmx is a protocol carried entirely in HTTP headers. Requests announce
	themselves with HX-Request and describe what triggered them; responses can
	steer the client -- redirect it, retarget the swap, push history, fire
	client-side events -- without a line of JavaScript. This module is that
	protocol, typed, so a misspelled header fails at the call site instead of
	being silently ignored by the browser.

	The single most useful thing here is `page`: one handler that answers a
	full document on a normal navigation and a bare fragment when htmx asks
	for the same URL. Writing that by hand for every route is the boilerplate
	that makes people give up on htmx and reach for a SPA.
]]
local Html = require("@web/html")
local Response = require("@web/response")
local Json = require("@web/json")

local Htmx = {}

-- =============================== requests ===============================

type Request = { headers: { [string]: string } }

local function header(request: Request, name: string): string?
	local value = request.headers[name]
	if value == nil or value == "" then
		return nil
	end
	return value
end

-- Did htmx issue this request, as opposed to the browser navigating?
function Htmx.isRequest(request: Request): boolean
	return header(request, "hx-request") == "true"
end

-- A boosted request is a plain link or form that hx-boost intercepted. It is
-- an htmx request, but the user still expects a whole page.
function Htmx.isBoosted(request: Request): boolean
	return header(request, "hx-boosted") == "true"
end

-- The id of the element that triggered the request, if it had one.
function Htmx.trigger(request: Request): string?
	return header(request, "hx-trigger")
end

function Htmx.triggerName(request: Request): string?
	return header(request, "hx-trigger-name")
end

-- The id of the element the response will be swapped into.
function Htmx.target(request: Request): string?
	return header(request, "hx-target")
end

function Htmx.currentUrl(request: Request): string?
	return header(request, "hx-current-url")
end

-- The answer to hx-prompt, if the trigger asked for one.
function Htmx.prompt(request: Request): string?
	return header(request, "hx-prompt")
end

-- True when this is a history restore, which should not be treated as a
-- normal swap: htmx is repopulating its cache.
function Htmx.isHistoryRestore(request: Request): boolean
	return header(request, "hx-history-restore-request") == "true"
end

-- =============================== responses ===============================

--[[
	A full-page redirect the browser performs itself.

	This is almost always what you want after a session expires or an action
	completes. Answering a 303 to an htmx request does NOT redirect the page:
	htmx follows it and swaps the result into the target, so a login page ends
	up inside a table cell. HX-Redirect makes the client navigate instead.
]]
function Htmx.redirect(response: Response.T, url: string): Response.T
	response.headers["hx-redirect"] = url
	return response
end

-- A client-side navigation: htmx fetches the URL and swaps it in, updating
-- history, without a full document reload.
function Htmx.location(response: Response.T, url: string): Response.T
	response.headers["hx-location"] = url
	return response
end

function Htmx.pushUrl(response: Response.T, url: string): Response.T
	response.headers["hx-push-url"] = url
	return response
end

function Htmx.replaceUrl(response: Response.T, url: string): Response.T
	response.headers["hx-replace-url"] = url
	return response
end

-- Force a full page reload once the response lands.
function Htmx.refresh(response: Response.T): Response.T
	response.headers["hx-refresh"] = "true"
	return response
end

-- Send this response somewhere other than the element that asked for it --
-- useful for routing an error into a shared banner rather than replacing the
-- form the user is still filling in.
function Htmx.retarget(response: Response.T, selector: string): Response.T
	response.headers["hx-retarget"] = selector
	return response
end

local SWAPS: { [string]: boolean } = {
	innerHTML = true, outerHTML = true, textContent = true,
	beforebegin = true, afterbegin = true, beforeend = true,
	afterend = true, delete = true, none = true,
}

function Htmx.reswap(response: Response.T, swap: string): Response.T
	-- The base kind may carry modifiers ("outerHTML swap:1s"), so only the
	-- first word is checked. An unknown one is a typo htmx would ignore.
	local kind = swap:match("^(%S+)") or swap
	if not SWAPS[kind] then
		error(`htmx: unknown swap "{kind}"`)
	end
	response.headers["hx-reswap"] = swap
	return response
end

--[[
	Fire client-side events when the response arrives.

	Pass a name for a bare event, or a table of name -> detail to send data
	with it. `stage` picks the moment: "receive" (default), "settle" or
	"swap" -- the later stages matter when the handler needs the new DOM to
	already be in place.
]]
function Htmx.triggerEvent(response: Response.T, events: string | { [string]: any }, stage: string?): Response.T
	local headerName = "hx-trigger"
	if stage == "settle" then
		headerName = "hx-trigger-after-settle"
	elseif stage == "swap" then
		headerName = "hx-trigger-after-swap"
	elseif stage ~= nil and stage ~= "receive" then
		error(`htmx: unknown trigger stage "{stage}"`)
	end
	response.headers[headerName] = if type(events) == "string"
		then events
		else Json.encode(events)
	return response
end

-- Answer an htmx request with nothing and no swap. The idiomatic reply to an
-- action whose only visible result is elsewhere on the page.
function Htmx.noContent(): Response.T
	local response = Response.html("", 204)
	response.headers["hx-reswap"] = "none"
	return response
end

-- ============================== rendering ==============================

--[[
	Answer a full document or a bare fragment from one handler.

	A normal navigation gets `shell(fragment)` -- your layout wrapped around
	the content. An htmx request gets the fragment alone, because htmx is
	swapping it into a page that already has the layout.

	Boosted requests deliberately get the full shell: hx-boost replaces the
	whole body, so a fragment would discard the navigation the user still
	needs. Getting this backwards produces a page that loses its chrome on
	the first click, which is the classic hx-boost bug.
]]
function Htmx.page(request: Request, shell: (any) -> Html.Node, fragment: Html.Node): Response.T
	if Htmx.isRequest(request) and not Htmx.isBoosted(request) then
		return Response.html(fragment)
	end
	return Response.html(shell(fragment))
end

--[[
	Mark a node for out-of-band swapping.

	An out-of-band node is swapped into the element with the same id ANYWHERE
	on the page, independently of the request's target. That is how one
	response updates two places at once -- a table row plus the unread badge
	in the header -- without a second round trip.
]]
function Htmx.oob(node: Html.Node, swap: string?): Html.Node
	local markup = Html.render(node)
	local tag, rest = markup:match("^<(%w+)(.*)$")
	if tag == nil then
		error("htmx.oob expects a single element node")
	end
	return Html.raw(`<{tag} hx-swap-oob="{swap or "true"}"{rest}`)
end

-- ============================== attributes ==============================

local ATTR_NAMES: { [string]: string } = {
	get = "hx-get", post = "hx-post", put = "hx-put",
	patch = "hx-patch", delete = "hx-delete",
	target = "hx-target", swap = "hx-swap", trigger = "hx-trigger",
	confirm = "hx-confirm", indicator = "hx-indicator",
	include = "hx-include", params = "hx-params", encoding = "hx-encoding",
	vals = "hx-vals", headers = "hx-headers", select = "hx-select",
	selectOob = "hx-select-oob", swapOob = "hx-swap-oob",
	pushUrl = "hx-push-url", replaceUrl = "hx-replace-url",
	boost = "hx-boost", disable = "hx-disable", disabledElt = "hx-disabled-elt",
	sync = "hx-sync", validate = "hx-validate", ext = "hx-ext",
	preserve = "hx-preserve", history = "hx-history", inherit = "hx-inherit",
}

--[[
	Build hx-* attributes from a table, checked at the call site.

	    h.button(hx.attrs({ post = "/kick", target = "#toast",
	                        confirm = "Kick this player?" }), "kick")

	The point is the error: `swp = "outerHTML"` is a typo the browser would
	ignore in silence, leaving a button that mysteriously does nothing. Here
	it raises. Any other key is passed through untouched, so class, id and
	the rest can share the same table.
]]
function Htmx.attrs(spec: { [string]: any }): { [string]: any }
	local out: { [string]: any } = {}
	for key, value in spec do
		local mapped = ATTR_NAMES[key]
		if mapped ~= nil then
			if key == "swap" and type(value) == "string" then
				local kind = value:match("^(%S+)") or value
				if not SWAPS[kind] then
					error(`htmx: unknown swap "{kind}"`)
				end
			end
			-- vals and headers are JSON-valued attributes; accept a table.
			if (key == "vals" or key == "headers") and type(value) == "table" then
				value = Json.encode(value)
			end
			out[mapped] = value
		elseif key:match("^hx%-") then
			out[key] = value -- already an hx-* attribute, pass through
		else
			out[key] = value -- class, id, type, ...
		end
	end
	return out
end

return Htmx
