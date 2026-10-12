--!strict
--[[
	JSON helpers over `@std/json`.

	Two things the raw library leaves to the caller and every route needs:
	decoding must never throw on malformed input (all of it arrives from the
	network), and `json.null` has to be flattened to `nil` before application
	code sees it, or every field read needs a null check of its own.
]]
local json = require("@std/json")

local Json = {}

Json.null = json.null

function Json.encode(value: any, pretty: boolean?): string
	return json.serialize(value, pretty or false)
end

--[[
	Strip a decoded value down to plain Luau data.

	Two things have to come out, and both are traps that surface far from here:

	  * `json.null` becomes nil, so field reads do not each need a null check.
	  * Decoded OBJECTS carry a userdata sentinel key that marks them as
	    objects rather than arrays. It is invisible until something iterates
	    the table -- `for key in decoded` yields it alongside the real keys,
	    and sorting those keys then dies with "attempt to compare string <
	    userdata". Dropping every non-string, non-number key removes it.

	The cost is that a decoded empty object re-serializes as `[]` rather than
	`{}`, since the marker is gone. Nothing here round-trips decoded values
	back out -- responses are built fresh -- so that trade is free.
]]
local function denull(value: any): any
	if value == json.null then
		return nil
	end
	if type(value) == "table" then
		local out: { [any]: any } = {}
		for key, item in value :: { [any]: any } do
			local keyType = type(key)
			if keyType ~= "string" and keyType ~= "number" then
				continue
			end
			local cleaned = denull(item)
			if cleaned ~= nil then
				out[key] = cleaned
			end
		end
		return out
	end
	return value
end

-- Returns nil plus a message rather than throwing, so a route can answer 400.
function Json.decode(text: string): (any?, string?)
	if text == "" then
		return nil, "empty body"
	end
	local ok, result = pcall(json.deserialize, text)
	if not ok then
		return nil, tostring(result)
	end
	return denull(result), nil
end

-- Decode and require an object at the top level.
function Json.decodeObject(text: string): ({ [string]: any }?, string?)
	local value, err = Json.decode(text)
	if value == nil then
		return nil, err or "no value"
	end
	if type(value) ~= "table" then
		return nil, "expected a JSON object"
	end
	return value :: { [string]: any }, nil
end

return Json
