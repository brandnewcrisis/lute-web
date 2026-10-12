--!strict
--[[
	Parsing request bodies and query strings.

	application/x-www-form-urlencoded is what a plain HTML form sends, so it
	is the body format a server like this deals with most. A form on a live
	page does not come through here at all: its fields arrive already parsed
	as `event.form`. Nothing here decodes multipart -- file uploads want streaming,
	which Lute's server does not expose.
]]
local Form = {}

local function decodeComponent(text: string): string
	-- '+' means space in form encoding but is a literal plus in a path, which
	-- is why this is only applied to form and query values.
	local swapped = text:gsub("+", " ")
	return (swapped:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16) :: number)
	end))
end

Form.decodeComponent = decodeComponent

function Form.encodeComponent(text: string): string
	return (text:gsub("[^%w%-%._~]", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

--[[
	Parse urlencoded pairs into a map.

	Repeated names keep the LAST value, matching how most frameworks behave
	for scalar fields. Use `parseMulti` when a field can legitimately repeat,
	such as a multi-select.
]]
function Form.parse(body: string): { [string]: string }
	local out: { [string]: string } = {}
	for pair in body:gmatch("[^&]+") do
		local key, value = pair:match("^([^=]*)=(.*)$")
		if key ~= nil and key ~= "" then
			out[decodeComponent(key)] = decodeComponent(value :: string)
		elseif pair ~= "" then
			out[decodeComponent(pair)] = "" -- a name with no "="
		end
	end
	return out
end

function Form.parseMulti(body: string): { [string]: { string } }
	local out: { [string]: { string } } = {}
	for pair in body:gmatch("[^&]+") do
		local key, value = pair:match("^([^=]*)=(.*)$")
		if key ~= nil and key ~= "" then
			local name = decodeComponent(key)
			if out[name] == nil then
				out[name] = {}
			end
			table.insert(out[name], decodeComponent(value :: string))
		end
	end
	return out
end

function Form.encode(values: { [string]: any }): string
	local names = {}
	for name in values do
		table.insert(names, name)
	end
	table.sort(names) -- stable output, so tests and caches behave
	local parts = {}
	for _, name in names do
		table.insert(parts, `{Form.encodeComponent(name)}={Form.encodeComponent(tostring(values[name]))}`)
	end
	return table.concat(parts, "&")
end

return Form
