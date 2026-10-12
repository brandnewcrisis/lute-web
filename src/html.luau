--!strict
--[[
	HTML construction that escapes by default.

	Almost everything this panel renders is attacker-influenced: faction and
	alliance names are typed by players, display names come from Roblox, and
	the remote console echoes back whatever a game server printed. Escaping
	therefore cannot be a thing the view layer remembers to do -- it is the
	default, and `raw` is the only way out.

	A node is a table carrying `__html`, already-safe markup. Plain strings are
	always treated as text and escaped on the way in, so a name like
	`<img onerror=...>` renders as visible characters rather than an element.
]]
local Html = {}

export type Node = { __html: string }

local ESCAPES: { [string]: string } = {
	["&"] = "&amp;",
	["<"] = "&lt;",
	[">"] = "&gt;",
	['"'] = "&quot;",
	["'"] = "&#39;",
}

--[[
	Escape text for use in element bodies and quoted attribute values.

	Both quote styles are escaped, not just the double quote, so a value
	dropped into a single-quoted attribute is equally safe. `&` must be first
	in the pattern set -- it is, since gsub with a character class replaces
	each character once, in one pass, so `<` never becomes `&amp;lt;`.
]]
function Html.escape(text: string): string
	return (text:gsub("[&<>\"']", ESCAPES))
end

-- Wrap markup that is already known safe. Every call is a place to double
-- check, which is why it is deliberately noisy to write.
function Html.raw(markup: string): Node
	return { __html = markup }
end

local function isNode(value: any): boolean
	return type(value) == "table" and type(value.__html) == "string"
end

-- Coerce anything a view might pass as a child into safe markup.
local function childMarkup(child: any): string
	if child == nil or child == false then
		return "" -- lets views write `condition and node` inline
	end
	if isNode(child) then
		return child.__html
	end
	if type(child) == "table" then
		-- a list of children
		local parts = {}
		for _, item in child :: { any } do
			table.insert(parts, childMarkup(item))
		end
		return table.concat(parts)
	end
	return Html.escape(tostring(child))
end

function Html.fragment(children: { any }): Node
	return { __html = childMarkup(children) }
end

--[[
	Block URLs that execute script when followed.

	`href` and `src` are the two attributes where an escaped string is still
	dangerous: quoting `javascript:alert(1)` correctly does not stop a click
	from running it. Only same-document, root-relative and http(s) URLs pass;
	anything else collapses to "#".
]]
local function safeUrl(url: string): string
	local trimmed = url:gsub("^%s+", "")
	local lower = trimmed:lower()
	if lower:match("^https?://") or trimmed:sub(1, 1) == "/" or trimmed:sub(1, 1) == "#" or trimmed:sub(1, 1) == "?" then
		return trimmed
	end
	-- Relative paths with no scheme are fine; a scheme we did not allow is not.
	if lower:match("^[%a][%w+.-]*:") then
		return "#"
	end
	return trimmed
end

local URL_ATTRS: { [string]: boolean } = { href = true, src = true, action = true, formaction = true }

-- Elements that must not be given a closing tag.
local VOID: { [string]: boolean } = {
	area = true, base = true, br = true, col = true, embed = true, hr = true,
	img = true, input = true, link = true, meta = true, source = true,
	track = true, wbr = true,
}

local function renderAttrs(attrs: { [string]: any }): string
	local parts = {}
	-- Sorted so identical attribute tables always render identically, which
	-- keeps htmx swaps and any snapshot test stable.
	local names = {}
	for name in attrs do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		local value = attrs[name]
		if value == nil or value == false then
			continue -- omit the attribute entirely
		end
		-- Reject attribute names outright rather than escaping them: a name is
		-- never legitimately dynamic here, so anything odd is a bug or an
		-- injection attempt, and both should be loud.
		if name:match("^[%a][%w:_%-]*$") == nil then
			error(`html: unsafe attribute name "{name}"`)
		end
		if value == true then
			table.insert(parts, " " .. name) -- boolean attribute, e.g. `disabled`
			continue
		end
		local text = tostring(value)
		if URL_ATTRS[name:lower()] then
			text = safeUrl(text)
		end
		table.insert(parts, ` {name}="{Html.escape(text)}"`)
	end
	return table.concat(parts)
end

--[[
	Build an element.

	Called as `el(tag, attrs, ...children)`; the attribute table is optional,
	detected by being a plain table that is not itself a node.
]]
function Html.el(tag: string, ...: any): Node
	local first = (...)
	local attrs: { [string]: any } = {}
	local firstChild = 1
	if type(first) == "table" and not isNode(first) and (next(first) == nil or type((next(first))) == "string") then
		attrs = first :: any
		firstChild = 2
	end
	local children = {}
	for index = firstChild, select("#", ...) do
		table.insert(children, (select(index, ...)))
	end
	local open = `<{tag}{renderAttrs(attrs)}>`
	if VOID[tag] then
		return { __html = open }
	end
	return { __html = `{open}{childMarkup(children)}</{tag}>` }
end

-- Final markup for a response body.
function Html.render(node: Node): string
	return node.__html
end

--[[
	Tag shorthand: `h.div({ class = "row" }, "text")`.

	Resolved lazily and cached, so any tag works without a hand-written list
	and without paying a lookup cost after first use.
]]
return setmetatable(Html, {
	__index = function(self, tag: string): any
		if tag:match("^[%a][%w]*$") == nil then
			return nil
		end
		local builder = function(...: any): Node
			return Html.el(tag, ...)
		end
		rawset(self, tag, builder)
		return builder
	end,
}) :: typeof(Html) & { [string]: (...any) -> Node }
