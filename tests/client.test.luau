-- src/client.luau is generated from client/live.js. This fails when the two
-- have drifted, which means tools/embed.luau was not run after an edit.
local fs = require("@lute/fs")
local Client = require("@web/client")
local T = require("./check")

local handle = fs.open("./client/live.js", "r")
local source = fs.read(handle)
fs.close(handle)

T.check("src/client.luau matches client/live.js (run: lute run tools/embed.luau)", Client.source == source)
T.check("the client has a version for cache busting", #Client.version == 8)

T.done()
