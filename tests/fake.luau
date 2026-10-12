-- A browser, as far as the server can tell: something that sends text and
-- collects what comes back. Shared by the suites that drive live pages.
local Live = require("@web/live")
local Json = require("@web/json")

local Fake = {}

function Fake.browser(mount)
	local self = { inbox = {} }
	self.connection = { send = function(text) table.insert(self.inbox, (Json.decode(text))) end }
	function self.say(message) Live.receive(self.connection, Json.encode(message)) end
	function self.hello() self.say({ t = "hello", m = mount.id }) end
	function self.fire(handler, detail, n) self.say({ t = "e", h = handler, n = n or 1, d = detail or { type = "click" } }) end
	-- Follow a link, or with `pop`, press back.
	function self.visit(url, pop) self.say({ t = "nav", u = url, n = 1, pop = pop }) end
	-- Flush, then hand back and clear everything received.
	function self.take()
		mount:flush()
		local got = self.inbox
		self.inbox = {}
		return got
	end
	-- The patches from everything received, flattened.
	function self.patches()
		local out = {}
		for _, message in self.take() do
			if message.t == "p" then
				for _, patch in message.p do table.insert(out, patch) end
			end
		end
		return out
	end
	return self
end

-- Build a page at a URL and connect a browser to it.
function Fake.page(component, path)
	local mount = Live.mount(component, if path then { path = path, query = {}, url = path } else nil)
	Live.register(mount)
	local tab = Fake.browser(mount)
	tab.hello()
	return mount, tab
end

return Fake
