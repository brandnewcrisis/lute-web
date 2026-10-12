--!strict
--[[
	Elements, written the way Vide writes instances.

	    create "button" {
	        class = "btn",
	        onclick = function() count(count() + 1) end,
	        function() return `clicked {count()} times` end,
	    }

	One table: string keys are attributes, the array part is children. A
	function where a value could go makes that spot reactive, and a function
	under an `on...` key is an event handler that runs here, on the server.

	Text is escaped on the way in. That is not a setting. Almost everything a
	page shows was typed by somebody else, so escaping cannot be a thing the
	view remembers to do: `raw` is the only way to put markup in unescaped.

	Unlike v1, a node is a small tree and not a finished string. It has to
	be: a row that outlives a re-render of the list around it must come out
	with what it shows now, not what it showed when it was built.
]]
local Graph = require("@web/graph")

local Html = {}

local NodeMeta = {}
NodeMeta.__index = NodeMeta

type Dyn = { name: string, value: any, sent: any }

type NodeData = {
	kind: "el" | "raw" | "frag" | "region",
	-- el
	tag: string?,
	open: string?,
	void: boolean?,
	lid: number?,
	key: string?,
	dyn: { Dyn }?,
	text: string?,
	-- el, frag, region
	children: { any }?,
	-- raw
	html: string?,
	-- region
	id: number?,
	sent: any,
}

export type Node = typeof(setmetatable({} :: NodeData, NodeMeta))
export type Props = { [any]: any }

--[[
	What the live layer has to provide for a page to be reactive. Html only
	ever sees this much of it, which keeps the two files honest about who
	knows what.
]]
export type Mount = {
	allocate: (self: any) -> number,
	handler: (self: any, fn: (any) -> ()) -> number,
	touch: (self: any, node: any, what: any?) -> (),
}

local ESCAPES: { [string]: string } = {
	["&"] = "&amp;",
	["<"] = "&lt;",
	[">"] = "&gt;",
	['"'] = "&quot;",
	["'"] = "&#39;",
}

-- Escape text for element bodies and quoted attribute values. Both quote
-- styles go, so a value is safe in either kind of attribute.
function Html.escape(text: string): string
	return (text:gsub("[&<>\"']", ESCAPES))
end

local escape = Html.escape

local function isNode(value: any): boolean
	return type(value) == "table" and getmetatable(value) == NodeMeta
end

Html.isNode = isNode

-- Markup that is already safe. Every call is a place to double check, which
-- is why there is no shorter way to write it.
function Html.raw(markup: string): Node
	return setmetatable({ kind = "raw", html = markup } :: NodeData, NodeMeta)
end

--[[
	Block URLs that run script when followed.

	Quoting `javascript:alert(1)` correctly does not stop a click from running
	it, so the URL attributes get a second check: same-document, relative and
	http(s) pass, any other scheme collapses to "#".
]]
local function safeUrl(url: string): string
	local trimmed = url:gsub("^%s+", "")
	local lower = trimmed:lower()
	local first = trimmed:sub(1, 1)
	if lower:match("^https?://") or first == "/" or first == "#" or first == "?" then
		return trimmed
	end
	if lower:match("^[%a][%w+.-]*:") then
		return "#"
	end
	return trimmed
end

local URL_ATTRS: { [string]: boolean } = { href = true, src = true, action = true, formaction = true }

local VOID: { [string]: boolean } = {
	area = true, base = true, br = true, col = true, embed = true, hr = true,
	img = true, input = true, link = true, meta = true, source = true,
	track = true, wbr = true,
}

-- Elements whose content is text and nothing else. A comment marker inside
-- <title> would be shown as text, so a reactive child here binds the
-- element's whole text instead of a region inside it.
local TEXT_ONLY: { [string]: boolean } = { title = true, textarea = true, option = true }

-- Elements whose content is not HTML at all and must not be escaped.
local RAW_TEXT: { [string]: boolean } = { script = true, style = true }

--[[
	Events a handler can be attached to.

	A fixed list so that `onclik` raises here instead of rendering an
	attribute nothing listens for. `focus` and `blur` are delivered through
	their bubbling forms in the browser.
]]
local EVENTS: { [string]: boolean } = {
	click = true, dblclick = true, input = true, change = true, submit = true,
	keydown = true, keyup = true, focus = true, blur = true,
}

--[[
	Turn an attribute value into what will be written: a string, `true` for
	a bare attribute, or nil for none. `class` takes a list and drops the
	falsy entries, so a conditional class needs no string building.
]]
local function attrValue(name: string, value: any): any
	if value == nil or value == false then
		return nil
	end
	if value == true then
		return true
	end
	local text: string
	if type(value) == "table" then
		if name ~= "class" then
			error(`html: attribute "{name}" was given a table; only class takes a list`, 0)
		end
		local parts = {}
		for index = 1, table.maxn(value) do
			local part = value[index]
			if part then
				table.insert(parts, tostring(part))
			end
		end
		text = table.concat(parts, " ")
	else
		text = tostring(value)
	end
	if URL_ATTRS[name] then
		text = safeUrl(text)
	end
	return text
end

local function writeAttr(name: string, value: any): string
	if value == nil then
		return ""
	end
	if value == true then
		return " " .. name
	end
	return ` {name}="{escape(value)}"`
end

local function currentMount(): Mount?
	local scope = Graph.getScope()
	if scope == nil then
		return nil
	end
	return Graph.mountOf(scope)
end

-- Run `compute` as an effect owned by the current scope.
local function bind(compute: () -> ())
	local node = Graph.createNode(Graph.requireScope("create"), function()
		compute()
		return nil
	end, nil)
	Graph.evaluate(node)
end

local append: (list: { any }, child: any, mount: Mount?) -> ()

--[[
	A reactive stretch of children.

	Rendered between two comment markers so the browser can find it again:
	a region can hold text, several elements or nothing, and none of those
	can carry an id of their own.
]]
local function region(fn: () -> any, mount: Mount): Node
	local node = setmetatable({ kind = "region", id = mount:allocate(), children = {} } :: NodeData, NodeMeta)
	local first = true
	bind(function()
		local list = {}
		append(list, fn(), mount)
		node.children = list
		if first then
			first = false
			-- What the browser will have. Remembered only for the common
			-- small case, a bound piece of text, so a rerun that comes out
			-- the same can be seen to and not sent.
			if #list == 1 and type(list[1]) == "string" and #list[1] <= 256 then
				node.sent = list[1]
			end
		else
			mount:touch(node)
		end
	end)
	return node
end

function append(list: { any }, child: any, mount: Mount?)
	local kind = type(child)
	if child == nil or kind == "boolean" then
		return -- so views can write `condition and node`
	end
	if kind == "string" then
		table.insert(list, escape(child))
	elseif kind == "number" then
		table.insert(list, tostring(child))
	elseif kind == "function" then
		if mount then
			table.insert(list, region(child, mount))
		else
			-- Nothing to keep current outside a live page: read it once.
			append(list, (child :: () -> any)(), nil)
		end
	elseif kind == "table" then
		if getmetatable(child) == NodeMeta then
			table.insert(list, child)
			return
		end
		for key in child do
			if type(key) ~= "number" then
				error(`html: a list of children has the key "{tostring(key)}"; attributes belong in the table given to create`, 0)
			end
		end
		for index = 1, table.maxn(child) do
			append(list, child[index], mount)
		end
	else
		table.insert(list, escape(tostring(child)))
	end
end

-- Flatten children to plain text, for the elements that can hold nothing else.
local function textOf(child: any, parts: { string }, tag: string)
	local kind = type(child)
	if child == nil or kind == "boolean" then
		return
	end
	if kind == "function" then
		textOf((child :: () -> any)(), parts, tag)
	elseif kind == "table" then
		if getmetatable(child) == NodeMeta then
			error(`html: <{tag}> can only contain text`, 0)
		end
		for index = 1, table.maxn(child) do
			textOf(child[index], parts, tag)
		end
	else
		table.insert(parts, tostring(child))
	end
end

--[[
	Split a props table into attributes and children.

	A plain table among the children is another layer of props, as in Vide,
	which is what lets attribute bundles be shared:

	    local danger = { class = "btn btn-danger", type = "button" }
	    create "button" { danger, "Delete" }

	Layers are applied first and the table's own keys last, so what is
	written at the call site wins over what came from a bundle.
]]
local function collect(props: Props, attrs: { [string]: any }, children: { any })
	for index = 1, table.maxn(props) do
		local child = props[index]
		if type(child) == "table" and getmetatable(child) ~= NodeMeta then
			collect(child, attrs, children)
		elseif child ~= nil then
			table.insert(children, child)
		end
	end
	for key, value in props do
		if type(key) == "string" then
			attrs[key] = value
		elseif type(key) ~= "number" then
			error(`html: a {type(key)} cannot be a property name`, 0)
		end
	end
end

local function build(tag: string, props: Props): Node
	if type(props) ~= "table" or getmetatable(props) == NodeMeta then
		error(`html: create "{tag}" takes one table of attributes and children`, 3)
	end
	local attrs: { [string]: any } = {}
	local children: { any } = {}
	collect(props, attrs, children)

	local node = setmetatable({ kind = "el", tag = tag, void = VOID[tag] or false } :: NodeData, NodeMeta)
	local mount: Mount? = nil
	local mountKnown = false
	local addressed = false
	local function live(): Mount?
		if not mountKnown then
			mountKnown = true
			mount = currentMount()
		end
		return mount
	end

	-- Sorted, so the same attributes always render the same markup.
	local names: { string } = {}
	for name in attrs do
		table.insert(names, name)
	end
	table.sort(names)

	local parts = { "<", tag }
	local dyn: { Dyn }? = nil
	for _, name in names do
		local value = attrs[name]
		-- A name is never legitimately dynamic, so an odd one is a bug or an
		-- injection attempt. Either should be loud, not escaped.
		if name:match("^[%a][%w:_.%-]*$") == nil then
			error(`html: unsafe attribute name "{name}"`, 0)
		end
		if name == "key" then
			-- Identity among siblings; see README, "Lists".
			if value ~= nil and value ~= false then
				node.key = tostring(value)
			end
		elseif type(value) == "function" then
			local event = name:match("^on(%l+)$")
			if event then
				if not EVENTS[event] then
					error(`html: no "{name}" event; handlers can be attached to on` .. "click, dblclick, input, change, submit, keydown, keyup, focus and blur", 0)
				end
				local page = live()
				if page == nil then
					error(`html: {name} was given a function outside a live page. Handlers run on the server, so the element has to be created inside app.page`, 0)
				end
				table.insert(parts, ` data-on-{event}="{(page :: Mount):handler(value)}"`)
			elseif live() then
				local slot: Dyn = { name = name, value = nil, sent = nil }
				local page = mount :: Mount
				local first = true
				bind(function()
					slot.value = attrValue(name, (value :: () -> any)())
					if first then
						first = false
						slot.sent = slot.value
					else
						page:touch(node, slot)
					end
				end)
				addressed = true
				dyn = dyn or {}
				table.insert(dyn :: { Dyn }, slot)
			else
				table.insert(parts, writeAttr(name, attrValue(name, (value :: () -> any)())))
			end
		else
			table.insert(parts, writeAttr(name, attrValue(name, value)))
		end
	end
	node.open = table.concat(parts)
	node.dyn = dyn

	if node.void then
		if #children > 0 then
			error(`html: <{tag}> cannot have children`, 0)
		end
	elseif RAW_TEXT[tag] then
		local text = {}
		for _, child in children do
			if type(child) ~= "string" then
				error(`html: <{tag}> takes its content as a plain string`, 0)
			end
			if child:lower():find("</" .. tag, 1, true) then
				error(`html: <{tag}> content contains its own closing tag`, 0)
			end
			table.insert(text, child)
		end
		node.children = text
	elseif TEXT_ONLY[tag] then
		local reactive = false
		for _, child in children do
			reactive = reactive or type(child) == "function"
		end
		local function compute()
			local text = {}
			textOf(children, text, tag)
			node.text = table.concat(text)
			node.children = { escape(node.text :: string) }
		end
		local page = if reactive then live() else nil
		if page then
			addressed = true
			local first = true
			bind(function()
				compute()
				if first then
					first = false
					node.sent = node.text
				else
					page:touch(node, "text")
				end
			end)
		else
			compute()
		end
	else
		local list = {}
		local hasFunction = false
		for _, child in children do
			hasFunction = hasFunction or type(child) == "function"
		end
		local page = if hasFunction then live() else nil
		for _, child in children do
			append(list, child, page)
		end
		node.children = list
	end

	-- Anything the browser has to find again by itself needs an address.
	if addressed then
		node.lid = (mount :: Mount):allocate()
	end
	return node
end

local constructors: { [string]: (Props) -> Node } = {}

local function constructor(tag: string): (Props) -> Node
	local existing = constructors[tag]
	if existing then
		return existing
	end
	if type(tag) ~= "string" or tag:match("^[%a][%w%-]*$") == nil then
		error(`html: "{tostring(tag)}" is not a tag name`, 3)
	end
	local function make(props: Props): Node
		return build(tag, props)
	end
	constructors[tag] = make
	return make
end

--[[
	Make an element: `create "div" { ... }`.

	`create "div"` alone returns the constructor, which is what makes the
	no-parentheses form work and lets one be kept: `local div = create "div"`.
]]
function Html.create(tag: string, props: Props?): any
	local make = constructor(tag)
	if props ~= nil then
		return make(props)
	end
	return make
end

-- Several nodes side by side with no element around them.
function Html.fragment(children: { any }): Node
	local list = {}
	append(list, children, currentMount())
	return setmetatable({ kind = "frag", children = list } :: NodeData, NodeMeta)
end

local function write(out: { string }, node: any)
	if type(node) == "string" then
		table.insert(out, node)
		return
	end
	local kind = node.kind
	if kind == "el" then
		table.insert(out, node.open)
		if node.key then
			table.insert(out, ` data-key="{escape(node.key)}"`)
		end
		if node.lid then
			table.insert(out, ` data-l="{node.lid}"`)
		end
		if node.dyn then
			for _, slot in node.dyn do
				table.insert(out, writeAttr(slot.name, slot.value))
			end
		end
		table.insert(out, ">")
		if not node.void then
			for _, child in node.children do
				write(out, child)
			end
			table.insert(out, `</{node.tag}>`)
		end
	elseif kind == "region" then
		table.insert(out, `<!--[{node.id}-->`)
		for _, child in node.children do
			write(out, child)
		end
		table.insert(out, `<!--]{node.id}-->`)
	elseif kind == "frag" then
		for _, child in node.children do
			write(out, child)
		end
	else
		table.insert(out, node.html)
	end
end

-- The markup for a node as it stands now.
function Html.render(node: any): string
	local out: { string } = {}
	if isNode(node) then
		write(out, node)
	else
		local list = {}
		append(list, node, nil)
		for _, child in list do
			write(out, child)
		end
	end
	return table.concat(out)
end

-- The markup inside a region, without its markers. What a patch carries.
function Html.inner(node: Node): string
	local out: { string } = {}
	for _, child in node.children :: { any } do
		write(out, child)
	end
	return table.concat(out)
end

NodeMeta.__tostring = function(self: any): string
	return Html.render(self)
end

return Html
