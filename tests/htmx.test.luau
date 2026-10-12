local hx = require("@web/htmx")
local h = require("@web/html")
local Response = require("@web/response")

local fails = 0
local function check(n, c, got) if not c then fails += 1; print("FAIL " .. n .. (if got ~= nil then "  got: " .. tostring(got) else "")) else print("ok   " .. n) end end
local function req(headers) return { headers = headers or {} } end

-- request detection
check("isRequest true", hx.isRequest(req({ ["hx-request"] = "true" })))
check("isRequest false when absent", not hx.isRequest(req()))
check("isRequest false when empty", not hx.isRequest(req({ ["hx-request"] = "" })))
check("isBoosted", hx.isBoosted(req({ ["hx-boosted"] = "true" })))
check("trigger", hx.trigger(req({ ["hx-trigger"] = "kick-btn" })) == "kick-btn")
check("target", hx.target(req({ ["hx-target"] = "toast" })) == "toast")
check("prompt", hx.prompt(req({ ["hx-prompt"] = "why" })) == "why")
check("missing header is nil", hx.currentUrl(req()) == nil)
check("history restore", hx.isHistoryRestore(req({ ["hx-history-restore-request"] = "true" })))

-- response steering
local r = hx.redirect(Response.html("x"), "/login")
check("redirect header", r.headers["hx-redirect"] == "/login")
check("redirect keeps 200 (not 3xx)", r.status == 200)
check("pushUrl", hx.pushUrl(Response.html(""), "/a").headers["hx-push-url"] == "/a")
check("replaceUrl", hx.replaceUrl(Response.html(""), "/b").headers["hx-replace-url"] == "/b")
check("refresh", hx.refresh(Response.html("")).headers["hx-refresh"] == "true")
check("retarget", hx.retarget(Response.html(""), "#toast").headers["hx-retarget"] == "#toast")
check("reswap valid", hx.reswap(Response.html(""), "outerHTML").headers["hx-reswap"] == "outerHTML")
check("reswap with modifier", hx.reswap(Response.html(""), "outerHTML swap:1s").headers["hx-reswap"] ~= nil)
check("reswap rejects typo", not (pcall(hx.reswap, Response.html(""), "outerHtml")))

-- triggers
check("trigger event string", hx.triggerEvent(Response.html(""), "saved").headers["hx-trigger"] == "saved")
local te = hx.triggerEvent(Response.html(""), { refresh = { id = 3 } })
check("trigger event json", te.headers["hx-trigger"]:find("refresh") ~= nil, te.headers["hx-trigger"])
check("trigger after settle", hx.triggerEvent(Response.html(""), "x", "settle").headers["hx-trigger-after-settle"] == "x")
check("trigger after swap", hx.triggerEvent(Response.html(""), "x", "swap").headers["hx-trigger-after-swap"] == "x")
check("trigger rejects bad stage", not (pcall(hx.triggerEvent, Response.html(""), "x", "later")))

-- noContent
local nc = hx.noContent()
check("noContent 204", nc.status == 204 and nc.headers["hx-reswap"] == "none")

-- page: fragment vs full document
local function shell(inner) return h.html({}, h.body({}, inner)) end
local frag = h.div({ id = "f" }, "content")
local full = hx.page(req(), shell, frag)
check("normal nav gets shell", full.body:find("<html>") ~= nil, full.body)
local partial = hx.page(req({ ["hx-request"] = "true" }), shell, frag)
check("htmx gets bare fragment", partial.body == '<div id="f">content</div>', partial.body)
-- the classic hx-boost bug: boosted must still get the shell
local boosted = hx.page(req({ ["hx-request"] = "true", ["hx-boosted"] = "true" }), shell, frag)
check("boosted still gets shell", boosted.body:find("<html>") ~= nil)

-- oob
local oob = hx.oob(h.div({ id = "badge" }, "3"))
check("oob adds attribute", h.render(oob):find('hx%-swap%-oob="true"') ~= nil, h.render(oob))
check("oob keeps content and id", h.render(oob):find('id="badge"') ~= nil and h.render(oob):find(">3<") ~= nil)
check("oob custom swap", h.render(hx.oob(h.li({}, "x"), "beforeend")):find('hx%-swap%-oob="beforeend"') ~= nil)
check("oob rejects non-element", not (pcall(hx.oob, h.raw("just text"))))

-- attrs
local a = hx.attrs({ get = "/x", target = "#y", swap = "outerHTML", confirm = "Sure?", class = "btn" })
check("attrs maps get", a["hx-get"] == "/x")
check("attrs maps target", a["hx-target"] == "#y")
check("attrs maps confirm", a["hx-confirm"] == "Sure?")
check("attrs passes class through", a.class == "btn")
check("attrs rejects unknown swap", not (pcall(hx.attrs, { swap = "nonsense" })))
check("attrs encodes vals table", (hx.attrs({ vals = { a = 1 } })["hx-vals"] :: string):find("\"a\"") ~= nil)
check("attrs passes raw hx- through", hx.attrs({ ["hx-boost"] = "true" })["hx-boost"] == "true")
-- typo protection is the point: an unmapped key is left alone, but a mapped
-- one with a bad value raises
check("attrs keeps unknown key", hx.attrs({ id = "z" }).id == "z")

-- renders into real markup
local btn = h.button(hx.attrs({ post = "/kick", target = "#toast", confirm = "Kick?" }), "kick")
local markup = h.render(btn)
check("renders hx-post", markup:find('hx%-post="/kick"') ~= nil, markup)
check("renders hx-confirm escaped-safe", markup:find('hx%-confirm="Kick%?"') ~= nil, markup)

print(if fails == 0 then "\nALL PASS" else "\n" .. fails .. " FAILURES")
