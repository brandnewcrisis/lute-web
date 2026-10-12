local web = require("@web")
local T = require("./check")
local check, eq, raises = T.check, T.eq, T.raises

local create, raw, render, source = web.create, web.raw, web.render, web.source

-- escaping
eq("escape angle", web.escape("<b>"), "&lt;b&gt;")
eq("escape amp once", web.escape("a & b"), "a &amp; b")
eq("escape quotes", web.escape([[a"b'c]]), "a&quot;b&#39;c")
eq("child escaped", render(create "div" { "<script>alert(1)</script>" }), "<div>&lt;script&gt;alert(1)&lt;/script&gt;</div>")

-- the real attack: a name somebody else typed
local evil = [[Zerg" onmouseover="alert(1)]]
local out = render(create "span" { title = evil, evil })
check("attr injection blocked", out:find('onmouseover="alert') == nil, out)

-- one table: string keys are attributes, the array part is children
eq("create with a string", render(create "p" { "hi" }), "<p>hi</p>")
eq("create two-argument form", render(create("p", { "hi" })), "<p>hi</p>")
eq("attributes and children share the table", render(create "p" { class = "x", "hi" }), '<p class="x">hi</p>')
local li = create "li"
eq("a constructor can be kept", render(li { "a" }) .. render(li { "b" }), "<li>a</li><li>b</li>")
eq("attrs sorted", render(create "div" { id = "b", class = "a" }), '<div class="a" id="b"></div>')
eq("attr true is bare", render(create "input" { disabled = true, type = "text" }), '<input disabled type="text">')
eq("attr false omitted", render(create "input" { disabled = false, type = "text" }), '<input type="text">')
eq("class list drops falsy entries", render(create "i" { class = { "a", false, "b", nil, "c" } }), '<i class="a b c"></i>')
eq("data and namespaced attrs", render(create "b" { ["data-id"] = 3, ["xlink:href"] = "/x" }), '<b data-id="3" xlink:href="/x"></b>')
eq("key becomes data-key", render(create "li" { key = "p7", "x" }), '<li data-key="p7">x</li>')
eq("custom element", render(create "my-thing" { "x" }), "<my-thing>x</my-thing>")

-- children
eq("nested", render(create "ul" { create "li" { "a" }, create "li" { "b" } }), "<ul><li>a</li><li>b</li></ul>")
eq("number child", render(create "span" { 42 }), "<span>42</span>")
eq("false child skipped", render(create "div" { false, "x" }), "<div>x</div>")
eq("nil hole skipped", render(create "div" { "a", nil, "b" }), "<div>ab</div>")
eq("raw passes through", render(create "div" { raw("<b>bold</b>") }), "<div><b>bold</b></div>")
eq("fragment", render(web.fragment({ create "i" { "a" }, "b" })), "<i>a</i>b")
eq("render a list", render({ create "i" { "a" }, create "i" { "b" } }), "<i>a</i><i>b</i>")
eq("tostring renders", tostring(create "b" { "x" }), "<b>x</b>")

-- a plain table among the children is another layer of props
local bundle = { class = "btn", type = "button" }
eq("props bundle", render(create "button" { bundle, "Save" }), '<button class="btn" type="button">Save</button>')
eq("call site wins over bundle", render(create "button" { bundle, class = "big", "Save" }), '<button class="big" type="button">Save</button>')
local items = { create "li" { "a" }, create "li" { "b" } }
eq("a list of nodes as a child", render(create "ul" { items }), "<ul><li>a</li><li>b</li></ul>")

-- void, text-only and raw-text elements
eq("void no close", render(create "br" {}), "<br>")
raises("void with children", function() create "br" { "x" } end, "cannot have children")
eq("title text escaped", render(create "title" { "a < b" }), "<title>a &lt; b</title>")
raises("title takes only text", function() create "title" { create "b" { "x" } } end, "only contain text")
eq("script content not escaped", render(create "script" { "if (a < b) run()" }), "<script>if (a < b) run()</script>")
raises("script cannot close itself", function() create "script" { "x</SCRIPT>y" } end, "closing tag")

-- url safety
eq("js url blocked", render(create "a" { href = "javascript:alert(1)", "x" }), '<a href="#">x</a>')
eq("js url spaced blocked", render(create "a" { href = "  JaVaScRiPt:alert(1)", "x" }), '<a href="#">x</a>')
eq("data url blocked", render(create "a" { href = "data:text/html,<script>", "x" }), '<a href="#">x</a>')
eq("relative ok", render(create "a" { href = "/servers", "x" }), '<a href="/servers">x</a>')
eq("https ok", render(create "a" { href = "https://roblox.com", "x" }), '<a href="https://roblox.com">x</a>')
eq("query ok", render(create "a" { href = "?page=2", "x" }), '<a href="?page=2">x</a>')

-- loud failures
raises("bad attribute name", function() create "div" { ["on click"] = "x" } end, "unsafe attribute")
raises("create needs a table", function() (create :: any)("div", "text") end, "one table")
raises("bad tag name", function() create "di v" {} end, "not a tag")
raises("attributes in a child list", function() render(create "div" { function() return { class = "x" } end }) end, "attributes belong")
raises("table for a non-class attribute", function() create "div" { id = { "a" } } end, "only class")

-- outside a live page a function is read once and leaves no trace
local n = source(2)
eq("function child rendered once", render(create "p" { "n=", n }), "<p>n=2</p>")
eq("function attribute rendered once", render(create "p" { class = function() return "c" .. n() end }), '<p class="c2"></p>')
eq("render takes a component", render(function() return create "p" { n } end), "<p>2</p>")
raises("handler outside a live page", function() create "button" { onclick = function() end } end, "live page")
raises("unknown event", function() create "button" { onclik = function() end } end, 'no "onclik"')
eq("a string under on* is just an attribute", render(create "b" { onclick = "go()" }), '<b onclick="go()"></b>')

T.done()
