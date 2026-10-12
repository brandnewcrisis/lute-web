# lute-web

Reactive, server-rendered pages for [Lute](https://lute.luau.org), written the way
[Vide](https://github.com/centau/vide) writes UI, with a few things borrowed from
[Solid](https://www.solidjs.com), which Vide itself follows.

```luau
local web = require("@web")
local create, source = web.create, web.source

local count = source(0)

local app = web.app({ port = 8080 })

app.page("/", function()
    return create "button" {
        onclick = function() count(count() + 1) end,
        function() return `clicked {count()} times` end,
    }
end)

app.serve()
```

That is the whole program. The click handler runs on the server. The button's text
updates in every open tab. There is no client code to write, no build step, and no
template language: HTML is Luau tables, and state is a function you call.

Run `lute run examples/demo.luau` and open it in two tabs.

## How it works

Rendering a page builds its elements inside a scope, and the server keeps that scope
for as long as the tab is open. Every function you wrote where a value could go became
an effect in it. When a source changes, those effects run again on the server and the
difference is sent to the browser over a WebSocket: this stretch of the page now holds
this markup, this attribute now has this value. Events travel the other way and call
your handlers.

The browser half is one small script the library serves itself. It applies patches by
folding them into the nodes already on the page, so the caret, the scroll position and
whatever is half typed all survive an update.

**Where you create a source decides who shares it.**

```luau
local online = source(0)            -- module level: one for the whole server.
                                    -- A write shows up in every open tab.

app.page("/", function()
    local draft = source("")        -- inside the page: one per tab.
    ...
end)
```

## Elements

`create "tag" { ... }` takes one table. String keys are attributes; the array part is
children.

```luau
create "a" { href = "/players", class = "link", "Players" }
```

```luau
create "ul" {
    class = "menu",

    create "li" { "one" },
    create "li" { "two" },
}
```

`create "li"` on its own returns the constructor, so one can be kept:
`local li = create "li"`.

**Text is escaped, always.** `create "span" { title = name, name }` is safe whatever `name`
holds. `web.raw(markup)` is the only way to put markup in unescaped. `href`, `src`,
`action` and `formaction` also refuse `javascript:` and `data:` URLs, and an odd
attribute name raises instead of being written.

A few conveniences:

- `false` and `nil` children are skipped, so `condition and create "p" { ... }` works inline.
- `class` takes a list and drops the falsy entries: `class = { "row", selected and "on" }`.
- A plain table among the children is another layer of props, as in Vide. Bundles of
  attributes can be shared, and what is written at the call site wins:

  ```luau
  local danger = { class = "btn btn-danger", type = "button" }
  create "button" { danger, "Delete" }
  ```

- A component is a function that returns elements. There is nothing else to it.

## State

| | |
| --- | --- |
| `source(value)` | A value that can change. `count()` reads, `count(5)` writes. |
| `derive(fn)` | A value computed from sources. Recomputed when they change, passed on only when the result differs. |
| `effect(fn)` | Run `fn` now and again whenever a source it read changes. |
| `cleanup(fn)` | Run `fn` when the current scope is destroyed (or before an effect reruns). |
| `untrack(fn)` | Read sources without subscribing. |
| `batch(fn)` | Make several writes, rerun each affected effect once. |
| `context(default)` | A value handed down to everything created inside a call. |
| `read(value)` | Accept a value or a function returning one. |
| `root(fn)` | A scope of your own, for state that belongs to no page. |
| `every(seconds, fn)` | Call `fn` on an interval until the scope is destroyed. |
| `resource(key, fetch)` | Data that has to be waited for, as a source. See below. |

Put a function where a value could go and that spot becomes reactive:

```luau
create "p" {
    class = function() return if count() > 9 then "big" else nil end,   -- attribute
    "Count: ", count,                                                   -- child
}
```

A source is itself a function, so `count` on its own is a reactive child.

Writing the same table back counts as a change, so the usual way to update a list is to
mutate it and write it back: `table.insert(list(), item); list(list())`.

## Control flow

A plain function child rebuilds everything it returns each time it runs. These keep the
scope of whatever did not change, so a row that is still in the list keeps its own state.

```luau
-- one of several
switch(tab) {
    players = PlayerList,
    bans = BanList,
}

-- there or not; the component gets a source of the truthy value
show(selected, function(player)
    return create "aside" {
        function() return player().name end,
    }
end, function()
    return create "p" { "Nobody selected" }
end)

-- a list where each ITEM keeps its scope
values(todos, function(todo, index)
    return create "li" { index, ". ", todo.text }
end)

-- a list where each POSITION keeps its scope
indexes(scores, function(score, index)
    return create "li" { score }
end)
```

Use `values` for things with an identity (rows, players, messages) and `indexes` for
plain strings or numbers that may repeat.

Rows made by `values` are given an identity the browser can follow, so a row that moves
is moved, not rewritten into its neighbour. To name one yourself, set `key`:
`create "li" { key = player.id, ... }`.

## Loading data

Effects cannot wait, so something slow follows a source through a `resource`, which is
Solid's `createResource`:

```luau
local query = source("")

local players, status = resource(query, function(text)
    return db:query("select * from players where name like ?", text .. "%")
end)

create "ul" {
    class = function() return if status.loading() then "stale" else nil end,
    indexes(function() return players() or {} end, PlayerRow),
}
```

Whenever `query()` changes, the fetcher runs with the new value and its result becomes
`players()`. The previous result stays on screen while the next one loads. If a newer
load finishes before an older one, the older answer is dropped.

- `status.loading()` and `status.error()` are sources. A failed load keeps the last good
  value and puts the message in `error()`.
- `status.refetch()` loads again; `status.mutate(value)` sets the value by hand.
- A key of `nil` or `false` means there is nothing to load yet.
- `resource(fetch)` with no key loads once.

**The first load is waited for** when the resource is created in a page function. The
page is sent with its data already in it, so no loading state flashes by on arrival.

## Containing failures

```luau
boundary(function()
    return PlayerCard(player)
end, function(message, retry)
    return create "p" {
        class = "error",
        "This card could not be shown. ",
        create "button" { onclick = retry, "Try again" },
    }
end)
```

If the component raises while being built, or an effect inside it raises later, what it
made is destroyed and the fallback takes its place. The error is logged either way.
Without a boundary, an error while building answers 500 for the whole page, and an error
in a later rerun is logged and leaves that part of the page showing what it last showed.

## Events

A function under an `on...` key is a handler. It runs on the server, outside any
reactive scope, so it may wait on a database or a request and then write a source.

```luau
create "input" {
    name = "q",
    oninput = function(event) query(event.value) end,
}

create "form" {
    ["data-reset"] = true,
    onsubmit = function(event)
        db:exec("insert into notes(text) values (?)", event.form.text)
        notes(db:query("select * from notes"))
    end,
    create "input" { name = "text" },
    create "button" { "Add" },
}
```

Events: `onclick`, `ondblclick`, `oninput`, `onchange`, `onsubmit`, `onkeydown`,
`onkeyup`, `onfocus`, `onblur`. A misspelled one raises when the element is built.

The handler receives:

| field | |
| --- | --- |
| `type` | the event name |
| `value` | the element's value, for inputs, selects and textareas |
| `checked` | for checkboxes and radios |
| `name` | the element's `name` |
| `form` | every field of the form, for `onsubmit` |
| `key`, `ctrl`, `shift`, `alt`, `meta` | for key events |

A handler on a container hears its children too: `oninput` on a `<form>` is called for
each field, with that field's `name` and `value`.

Plain attributes tune how the browser sends an event:

| attribute | |
| --- | --- |
| `data-confirm="Sure?"` | ask before sending a click or submit |
| `data-reset` | on a form: clear it as it is sent, ready for the next entry |
| `data-debounce="300"` | wait this many ms of quiet before sending. `input` defaults to 150 |
| `data-keys="Enter Escape"` | send key events only for these keys |
| `data-live-ignore` | the browser owns this element's children; updates leave them alone |

While a click or submit is on its way the element carries `aria-busy="true"`, which is
all a stylesheet needs to dim a button, and a second click is dropped.

**Typing is never overwritten.** An input can be bound both ways (`value = text` with an
`oninput` that writes `text`), and the server may set it to anything. But while a person
is typing in a box that holds text the server has not seen yet, a value arriving from
the server is not put on top of it. To empty a box after an entry, use `data-reset`:
it happens in the browser at the moment of sending, so nothing typed afterwards is lost.

From inside a handler:

- `web.navigate(url)` sends the browser somewhere else (in place, on a routed page).
- `web.reload()` builds the page afresh.
- `web.emit(name, detail)` fires a DOM event on `document`, for the few things that must
  happen client-side (focus this, copy that). A script of yours listens for it.

## Pages

```luau
app.page("/players/:id", function(request)
    local player = db:first("select * from players where id = ?", request.params.id)
    if player == nil then
        return web.Response.text("no such player", 404)
    end
    return Layout { PlayerCard(player) }
end)
```

A page function is a component. It is called with the request, may wait on I/O before
returning, and returns elements. Return `<html>` to supply the whole document; return
anything else and it is wrapped in a minimal one. Return a response instead (a redirect,
a 404) and that is sent as it is.

**A page with nothing reactive in it is sent as plain HTML**, with no script, and
nothing is kept for it. You do not choose between static and live; you get live where
you wrote a function.

What the server holds and for how long:

- A live page's scope lives while its tab is connected, and is destroyed when the tab
  closes or navigates away. `cleanup` runs then.
- A dropped connection is given `Live.linger` seconds (30) to come back. When it does,
  the browser is sent the page as it now stands and folds it in. State on both sides
  survives a flaky network or a closed laptop lid.
- If the server no longer has the page (it restarted, or the tab stayed away too long),
  the tab reloads.

The browser sets `data-live` on `<html>` to `connecting`, `on` or `off`, so a stylesheet
can show a "reconnecting" notice. It also fires `live:update` on `document` after every
update and `live:error` on an element whose handler failed.

## Routing

One document, many URLs, in the manner of Solid Router. `route` is `switch` keyed by
the address:

```luau
local route, link = web.route, web.link

app.page("/*", function()
    return create "body" {
        create "nav" {
            link { href = "/", "Home" },
            link { href = "/players", "Players" },
        },

        route {
            ["/"] = Home,
            ["/players"] = PlayerList,
            ["/players/:id"] = PlayerPage,
            ["*"] = NotFound,
        },
    }
end)
```

**Links are just links.** On a page that has a `route`, following any `<a href>` to
somewhere on the site does not load a new document. The browser tells the server where
it is going, the server builds the component for that URL in place of the old one, and
the address bar and history are updated. Back and forward work. Everything outside the
`route` (the nav above, a sidebar, whatever state they hold) is untouched.

A link is left to the browser when it has a `target`, `download`, `rel="external"` or
`data-reload`, when it points at another site, and when its URL belongs to something
else in the app (a plain route, a different page): the server says so and the browser
loads it the ordinary way. `before` is asked again on every move, so a URL it would
have refused is never shown in place.

**Components get their parameters as a source:**

```luau
local function PlayerPage(params)
    local player = resource(function() return params().id end, function(id)
        return db:first("select * from players where id = ?", id)
    end)

    return create "h1" { function() return player() and player().name end }
end
```

Moving from `/players/1` to `/players/2` fits the same pattern, so the component is
kept and `params()` changes. Moving to a different pattern builds the new component
first, then destroys the old one. The page being left stays on screen until its
replacement is ready, and the link that was followed carries `aria-busy` meanwhile.

Unlike `switch`, the swap runs where the navigation was asked for and not in an effect,
so a routed component may wait while it is built, and a `resource` in it has its first
load done before the page appears.

| | |
| --- | --- |
| `route { [pattern] = component }` | Show the component matching the URL. |
| `link { href = ..., ... }` | An `<a>` with `aria-current="page"` when it points at the current path, `"true"` when the path lies beneath it. |
| `location()` | A source: `.path`, `.query`, `.url`. |
| `navigate(url, { replace })` | Move from a handler. In place when a route can show it. |

Patterns: `/players/:id` captures a segment; a final `/*` takes everything below, with
the rest in `params()["*"]`; a bare `"*"` is the not-found page and answers 404. The most
specific pattern wins, whatever order the table is in.

**Routes nest.** A component under `"/admin/*"` can hold a `route` of its own for what
comes below it, and is kept while moving among those.

The app's own patterns take the same wildcard, which is what `app.page("/*", ...)` is.
A route without a wildcard always wins over one with, so a catch-all page never shadows
`/login` or the static files.

## Two rules

**Effects and derives must not wait.** A function given to `effect` or `derive`, or used
as an attribute or child, has to return promptly: no database call, no `task.wait`. It
raises if it tries. Do the waiting in the page function or in a handler, and write the
result to a source.

**State is in this process.** Pages are scopes in memory. A restart drops them (tabs
reload and carry on), and two instances behind a load balancer do not share them. For
anything that must outlive the process, write it to a database and read it back into a
source.

## Plain routes

Some jobs need an ordinary request and response: setting a cookie, serving JSON,
receiving a webhook. Those are still here.

```luau
app.post("/login", function(request)
    local form = web.Form.parse(request.body)
    ...
    return web.Response.withCookie(web.Response.redirect("/"), cookie)
end)
```

`app.get`, `post`, `put`, `patch`, `delete`. Options to `web.app`: `host`, `port`,
`staticDir`, `staticPrefix`, `before` (runs ahead of every route and page; return a
response to stop there), `onError`, and `debug` (send handler error text to the browser
console).

`web.render(nodeOrComponent)` renders to a string once, with nothing kept, for
fragments, emails and tests.

## The rest of the toolkit

| Module | |
| --- | --- |
| `Response` | `html` / `text` / `json` / `redirect`, plus strict security headers on every response. `configure` to adjust |
| `Router` | `/servers/:jobId/players` style params; 405 when the path exists under another verb |
| `Session` | stateless sessions sealed with `crypto.secretbox`; a restart does not sign everyone out |
| `Cookies` | parse and serialize; `HttpOnly` always, `SameSite=Lax` by default |
| `Form` | urlencoded bodies and query strings |
| `Static` | serves `./public` from memory, refuses anything with a path separator |
| `Bytes` `Hmac` `Json` `Log` | hex/base64url/CSPRNG, HMAC-SHA256, JSON with the `@std/json` sentinels stripped, logging with a file sink |

## Security

- **Escaping is the default** and cannot be turned off, only bypassed per call with `raw`.
  Patches go through the same path as the first render.
- **The CSP is strict**: `default-src 'self'`. No inline scripts, no inline styles (so
  no `style` attributes either; use classes). Live pages fit inside it.
- **A page's id is its credential.** It is 144 random bits, given only to whoever was
  served the page, and every message on the socket must come from a connection that
  presented it. Another site cannot fire your handlers. Live pages are sent `no-store`.
- **Handlers are closures.** They can only do what the page that rendered them was
  allowed to do, with the request and session that page was built from. Check
  permissions when building the page; re-check in a handler if a session might have been
  revoked since.
- Only one `Set-Cookie` per response (Lute models headers as a map). Keep anything else
  inside the session payload.

## Differences from Vide

The model is Vide's and so are the names. What differs follows from running on a server:

- Elements are HTML, so attributes are lowercase and events are `onclick`, not `Activated`.
- Scopes are tracked per coroutine. A page function may yield; an effect may not.
- A failing effect rerun is logged and does not throw from the write that triggered it,
  so one visitor's bug cannot stop another's update.
- Creating elements inside a reactive function is allowed. They are rebuilt with it.
- `show`, `switch`, `values` and `indexes` have no `present` source or delayed destroy.
  Exit animations belong to CSS here.
- `values` and `indexes` put items out in list order, since order is the layout.
- No `action`, `changed` or `spring`. Added: `every`, `navigate`, `reload`, `emit`,
  and from Solid, `resource`, `boundary` and routing (`route`, `link`, `location`).

## What is not here

Things Solid or a client framework would give you that this does not, on purpose or not
yet:

- **Stores.** Solid's `createStore` makes nested objects reactive through proxies. Luau's
  `table.insert`, `table.remove` and `#` bypass metamethods, so a proxy would silently
  miss the most common ways of changing a list. Use a source per thing that changes, as
  the demo does with each todo's `done`.
- **Suspense and transitions.** `status.loading()` and a class do the same job here.
- **Animation helpers.** No `spring` and no exit delay. Use CSS.
- **File uploads.** Lute's server does not expose multipart bodies.
- **More than one server process.** See "State is in this process" above.

## Coming from v1

v2 is a new library under the same name. The toolkit modules (`Response`, `Router`,
`Session`, `Cookies`, `Form`, `Static`, `Bytes`, `Hmac`, `Json`, `Log`) are unchanged.

| v1 | v2 |
| --- | --- |
| `web.App.new(opts)` | `web.app(opts)` (`web.App.new` still works) |
| `h.div({ class = "x" }, child, child)` | `create "div" { class = "x", child, child }` |
| `h.fragment({ a, b })` | `{ a, b }` anywhere a child goes; `web.fragment` for a node |
| `node.__html` | `web.render(node)` or `tostring(node)` |
| `web.htmx`, `hx-*` attributes, OOB swaps | gone: write a function where the value goes |
| a polling fragment route | a source, written from `every` or a handler |
| `hx-confirm` | `data-confirm` |
| `Response.hxRedirect(url)` | `web.navigate(url)` in a handler, `Response.redirect` in a route |
| `app.get(path, fullPageOrFragment)` | `app.page(path, component)` |

## Tests

```bash
lute run tests/run.luau
```

Twelve suites: the reactive graph and resources, control flow and boundaries, escaping
and element building, the live protocol driven through a fake connection, routing,
pages, and the toolkit modules.

The browser client lives in `client/live.js` and is embedded into `src/client.luau`.
After editing it, run `lute run tools/embed.luau`; a test fails if the two drift.

## Credit

The reactive graph, the element syntax and most of the API are
[Vide](https://github.com/centau/vide)'s, by centau (MIT), carried over to a server.
`resource`, `boundary` and `route` follow [Solid](https://www.solidjs.com)'s
`createResource`, `ErrorBoundary` and Solid Router.
