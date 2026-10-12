local Session = require("@web/session")
local Router = require("@web/router")
local Cookies = require("@web/cookies")

local fails = 0
local function check(name, cond)
	if not cond then fails += 1; print("FAIL " .. name) else print("ok   " .. name) end
end

local SECRET = "test-secret-key-abc123"

-- roundtrip
local data = Session.create(12345, "pilot", "Pilot", 3600)
local cookie = Session.seal(SECRET, data)
local opened = Session.open(SECRET, cookie)
check("roundtrip userId", opened ~= nil and opened.userId == 12345)
check("roundtrip name", opened ~= nil and opened.name == "pilot")
check("csrf present", opened ~= nil and #opened.csrf > 10)

-- tamper resistance
check("wrong secret rejected", Session.open("other-secret", cookie) == nil)
check("nil rejected", Session.open(SECRET, nil) == nil)
check("garbage rejected", Session.open(SECRET, "garbage") == nil)
check("malformed rejected", Session.open(SECRET, "abc.def") == nil)
local nonce, cipher = cookie:match("^([^.]+)%.([^.]+)$")
check("flipped ciphertext rejected", Session.open(SECRET, nonce .. "." .. cipher:sub(1, -2) .. (cipher:sub(-1) == "A" and "B" or "A")) == nil)

-- expiry
local expired = Session.create(1, "a", "A", -10)
check("expired rejected", Session.open(SECRET, Session.seal(SECRET, expired)) == nil)

-- two seals of same data differ (fresh nonce)
check("nonce fresh", Session.seal(SECRET, data) ~= Session.seal(SECRET, data))

-- cookies
local parsed = Cookies.parse("a=1; sb_panel=xyz.abc; b=2")
check("cookie parse", parsed.sb_panel == "xyz.abc" and parsed.a == "1")
check("cookie parse nil", next(Cookies.parse(nil)) == nil)
local ser = Cookies.serialize("sb_panel", "v", { maxAge = 60, secure = true })
check("cookie httponly", ser:find("HttpOnly") ~= nil)
check("cookie samesite", ser:find("SameSite=Lax") ~= nil)
check("cookie secure", ser:find("Secure") ~= nil)
check("cookie maxage", ser:find("Max%-Age=60") ~= nil)

-- router
local r = Router.new()
r.get("/servers", function() return nil :: any end)
r.get("/servers/:jobId/players", function() return nil :: any end)
r.post("/servers/:jobId/shutdown", function() return nil :: any end)

local h, params, matched = r.resolve("GET", "/servers")
check("route exact", h ~= nil)
h, params, matched = r.resolve("GET", "/servers/abc-123/players")
check("route param", h ~= nil and params.jobId == "abc-123")
h, params, matched = r.resolve("GET", "/nope")
check("route 404", h == nil and matched == false)
h, params, matched = r.resolve("POST", "/servers")
check("route 405 signal", h == nil and matched == true)
h, params, matched = r.resolve("GET", "/servers/a/b/c/d")
check("route no overreach", h == nil)

print(if fails == 0 then "\nALL PASS" else "\n" .. fails .. " FAILURES")
