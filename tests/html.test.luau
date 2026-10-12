local h = require("@web/html")

local fails = 0
local function check(name, cond, got)
	if not cond then fails += 1; print("FAIL " .. name .. (if got then "  got: " .. got else "")) else print("ok   " .. name) end
end
local function r(node) return h.render(node) end

-- escaping
check("escape angle", h.escape("<b>") == "&lt;b&gt;")
check("escape amp once", h.escape("a & b") == "a &amp; b", h.escape("a & b"))
check("escape no double", h.escape("<") == "&lt;", h.escape("<"))
check("escape quotes", h.escape([[a"b'c]]) == "a&quot;b&#39;c", h.escape([[a"b'c]]))

-- text children escaped
check("child escaped", r(h.div({}, "<script>alert(1)</script>"))
	== "<div>&lt;script&gt;alert(1)&lt;/script&gt;</div>", r(h.div({}, "<script>alert(1)</script>")))

-- the real attack: a player-chosen faction name
local evil = [[Zerg" onmouseover="alert(1)]]
local out = r(h.span({ title = evil }, evil))
check("attr injection blocked", out:find('onmouseover="alert') == nil, out)

-- attrs
check("attr sorted", r(h.div({ id = "b", class = "a" })) == '<div class="a" id="b"></div>', r(h.div({ id = "b", class = "a" })))
check("attr true bare", r(h.input({ disabled = true, type = "text" })) == '<input disabled type="text">', r(h.input({ disabled = true, type = "text" })))
check("attr false omitted", r(h.input({ disabled = false, type = "text" })) == '<input type="text">', r(h.input({ disabled = false, type = "text" })))
check("attr nil omitted", r(h.div({ id = nil, class = "a" })) == '<div class="a"></div>')
check("hx- attrs allowed", r(h.button({ ["hx-post"] = "/x" }, "go")) == '<button hx-post="/x">go</button>')

-- void elements
check("void no close", r(h.br({})) == "<br>")
check("img void", r(h.img({ src = "/a.png" })) == '<img src="/a.png">')

-- url safety
check("js url blocked", r(h.a({ href = "javascript:alert(1)" }, "x")) == '<a href="#">x</a>', r(h.a({ href = "javascript:alert(1)" }, "x")))
check("js url spaced blocked", r(h.a({ href = "  JaVaScRiPt:alert(1)" }, "x")) == '<a href="#">x</a>', r(h.a({ href = "  JaVaScRiPt:alert(1)" }, "x")))
check("data url blocked", r(h.a({ href = "data:text/html,<script>" }, "x")) == '<a href="#">x</a>')
check("relative ok", r(h.a({ href = "/servers" }, "x")) == '<a href="/servers">x</a>')
check("https ok", r(h.a({ href = "https://roblox.com" }, "x")) == '<a href="https://roblox.com">x</a>')
check("query ok", r(h.a({ href = "?page=2" }, "x")) == '<a href="?page=2">x</a>')

-- raw opt-out
check("raw passes through", r(h.div({}, h.raw("<b>bold</b>"))) == "<div><b>bold</b></div>")

-- nesting and lists
check("nested", r(h.ul({}, { h.li({}, "a"), h.li({}, "b") })) == "<ul><li>a</li><li>b</li></ul>", r(h.ul({}, { h.li({}, "a"), h.li({}, "b") })))
check("no attrs form", r(h.p({}, "hi")) == "<p>hi</p>")
check("false child skipped", r(h.div({}, false, "x")) == "<div>x</div>")
check("number child", r(h.span({}, 42)) == "<span>42</span>")

-- bad attribute name is loud
local okErr = pcall(function() return r(h.div({ ["on click"] = "x" })) end)
check("bad attr name errors", not okErr)

print(if fails == 0 then "\nALL PASS" else "\n" .. fails .. " FAILURES")
