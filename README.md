# lute-web

A small web toolkit for [Lute](https://lute.luau.org), built for
[htmx](https://htmx.org). No build step, no client framework, no template language —
HTML is Luau functions, and the server steers the client through response headers.

```luau
local web = require("@web")
local h, hx = web.html, web.htmx

local app = web.App.new({ port = 8080, staticDir = "./public" })

app.get("/", function(request)
    -- Full document on a normal visit, bare fragment when htmx asks.
    return hx.page(request, layout, todoList())
end)

app.post("/todo", function(request)
    local text = web.Form.parse(request.body).text
    return web.Response.html(todoList())
end)

app.serve()
```

Run `lute run examples/demo.luau` for a working app that exercises every idea below.

## Why it exists

Lute gives you `server.serve` and nothing else — no routing, no escaping, no cookies,
no sessions, no 404. This is that middle layer, written once and tested.

## HTML that escapes by default

The single most important thing here. `html` treats every string as text and escapes it
on the way in; raw markup is opt-in via `h.raw`.

```luau
h.span({ title = name }, name)
```

If `name` is `Zerg" onmouseover="alert(1)`, that renders as a visible string in both
places. There is no configuration where it does not, and the escaping happens where
values are *interpolated* rather than where they are *stored* — the only place it can
be applied reliably.

`href`, `src`, `action` and `formaction` additionally reject `javascript:` and `data:`
URLs, because correctly quoting `javascript:alert(1)` does not stop a click from running
it. Attribute *names* are validated too: a dynamic-looking name raises rather than
being escaped, since a name is never legitimately dynamic.

## htmx as a typed protocol

htmx is carried entirely in HTTP headers. `web.htmx` makes that surface explicit so a
misspelling fails at the call site instead of being silently ignored by the browser.

**Reading:** `isRequest`, `isBoosted`, `trigger`, `triggerName`, `target`,
`currentUrl`, `prompt`, `isHistoryRestore`.

**Steering:** `redirect`, `location`, `pushUrl`, `replaceUrl`, `refresh`, `retarget`,
`reswap`, `triggerEvent`, `noContent`.

```luau
-- After a session expires. A 303 here would NOT redirect the page: htmx
-- follows it and swaps the login form into whatever element asked.
return hx.redirect(web.Response.html(""), "/login")
```

**`hx.page(request, shell, fragment)`** is the one that earns its keep: one handler
answering a full document on navigation and a bare fragment on an htmx swap. Boosted
requests deliberately get the full shell — `hx-boost` replaces the whole body, so
returning a fragment there strips the navigation off the page on the first click.

**`hx.attrs`** builds `hx-*` attributes and validates them:

```luau
h.button(hx.attrs({ post = "/kick", target = "#toast", swap = "outerHTML",
                    confirm = "Kick this player?" }), "kick")
```

`swp = "outerHTML"` raises. Left unchecked, htmx ignores the unknown attribute and you
get a button that mysteriously does nothing.

**`hx.oob(node)`** marks a node for out-of-band swapping, so one response updates two
places — a table row and the unread badge in the header — without a second request.

> Include OOB nodes **only** in fragment responses. On a full page load the shell
> already renders that element, so an OOB copy draws a second one loose in the
> document. The demo hit exactly this; see the `withOob` parameter there.

## What else is in the box

| Module | |
| --- | --- |
| `App` | routing, 404/405, a `before` hook, and a `pcall` so a raising handler answers 500 instead of dropping the connection |
| `Router` | `/servers/:jobId/players` style params; answers 405 when the path exists under another verb |
| `Response` | `html` / `text` / `json` / `redirect`, plus strict security headers on every response — `configure` to adjust |
| `Session` | stateless sessions sealed with `crypto.secretbox`; unreadable and untamperable by the client, and a restart does not sign everyone out |
| `Cookies` | parse and serialize; `HttpOnly` always, `SameSite=Lax` by default |
| `Form` | urlencoded bodies and query strings, `parse` / `parseMulti` / `encode` |
| `Static` | serves `./public` from memory, refuses anything with a path separator |
| `Bytes` `Hmac` `Json` `Log` | hex/base64url/CSPRNG, HMAC-SHA256 (RFC 4231 vectors), JSON with the `@std/json` sentinels stripped, logging with a file sink |

Two defaults worth knowing:

**The CSP is strict** — `default-src 'self'`, no inline scripts or styles. htmx needs
neither, so an htmx app fits inside a policy most SPAs cannot. Serve `htmx.min.js` from
`public/` (a copy is included) rather than a CDN.

**Only one `Set-Cookie` per response.** Lute models response headers as a string map, so
a second cookie silently overwrites the first. Put CSRF tokens *inside* the session
payload rather than in a cookie of their own.

## Tests

```bash
lute run tests/run.luau
```

Seven suites: escaping and URL sanitising, the htmx header protocol, form decoding,
base64url against RFC 4648 vectors, HMAC against RFC 4231, session tamper-resistance,
and JSON sentinel handling.
