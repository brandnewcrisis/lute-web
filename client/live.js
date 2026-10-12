// lute-web live client.
//
// The page was rendered on the server and its state lives there. This file
// keeps the two in step: it applies the patches the server sends, and sends
// back the events the server asked to hear about. It holds no application
// state of its own and never needs editing per app.
//
// Source of truth for src/client.luau: run `lute run tools/embed.luau` after
// changing it.
(() => {
  "use strict";

  const script = document.currentScript || document.querySelector("script[data-live]");
  if (!script) return;
  const mountId = script.dataset.live;
  const socketPath = script.dataset.ws || "/_live/ws";
  const routed = script.dataset.routed !== undefined; // the page has routes of its own
  const root = document.documentElement;
  const SVG = "http://www.w3.org/2000/svg";

  let socket = null;
  let attempt = 0;
  let sequence = 0;
  let leaving = false;
  const backlog = []; // events raised while the socket was down
  const waiting = new Map(); // event number -> { el, source, value, reset }
  const regions = new Map(); // region id -> its opening marker
  const elements = new Map(); // element id -> element
  const timers = new Map(); // element -> pending debounced send

  const setState = (state) => { root.dataset.live = state; };

  // ---------------------------------------------------------------- lookup

  // A region is the run of nodes between <!--[id--> and <!--]id-->.
  function scanRegions() {
    regions.clear();
    const walker = document.createTreeWalker(document, NodeFilter.SHOW_COMMENT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (node.data.charCodeAt(0) === 91) regions.set(node.data.slice(1), node);
    }
  }

  function regionStart(id) {
    let node = regions.get(id);
    if (!node || !node.isConnected || node.data !== "[" + id) {
      scanRegions();
      node = regions.get(id);
    }
    return node;
  }

  function elementFor(id) {
    let el = elements.get(id);
    if (!el || !el.isConnected || el.getAttribute("data-l") !== id) {
      el = document.querySelector('[data-l="' + id + '"]');
      if (el) elements.set(id, el);
    }
    return el;
  }

  // ----------------------------------------------------------------- morph
  //
  // Fold new markup into the nodes already on the page instead of replacing
  // them. Replacing would be simpler and would also drop the caret, the
  // scroll position and whatever is half typed every time anything changed.

  const keyOf = (node) => (node.nodeType === 1 ? node.getAttribute("data-key") || node.id || null : null);

  function compatible(old, incoming) {
    if (old.nodeType !== incoming.nodeType) return false;
    if (old.nodeType === 8) return old.data === incoming.data; // markers are identities
    if (old.nodeType !== 1) return true;
    if (old.nodeName !== incoming.nodeName) return false;
    return old.nodeName !== "INPUT" || old.type === incoming.type;
  }

  // True for the input being typed into when it holds something the server
  // has not seen yet: typing still waiting out its debounce, or typed since
  // the last event sent. A value arriving from the server was worked out
  // from older text and must not land on top of the newer. The server is
  // told the newer text by the next event, so the two meet again there.
  function ahead(el) {
    if (el !== document.activeElement) return false;
    if (timers.has(el)) return true;
    const sent = el._sent;
    return Boolean(sent && sent.length && el.value !== sent[sent.length - 1]);
  }

  function setProperty(el, name, value) {
    if (name === "value" && "value" in el) {
      const next = value === null ? "" : value;
      if (el.value !== next && !ahead(el)) el.value = next;
    } else if (name === "checked" && "checked" in el) {
      el.checked = value !== null;
    } else if (name === "selected" && "selected" in el) {
      el.selected = value !== null;
    }
  }

  // Attributes the browser side owns: never removed because the server did
  // not mention them.
  function clientOwned(el, name) {
    if (name === "aria-busy") return true;
    if (name === "open") return el.nodeName === "DETAILS" || el.nodeName === "DIALOG";
    return el === root && name === "data-live";
  }

  function syncAttributes(old, incoming) {
    for (const { name } of Array.from(old.attributes)) {
      if (!incoming.hasAttribute(name) && !clientOwned(old, name)) {
        old.removeAttribute(name);
        setProperty(old, name, null);
      }
    }
    for (const { name, value } of Array.from(incoming.attributes)) {
      if (old.getAttribute(name) !== value) {
        old.setAttribute(name, value);
        setProperty(old, name, value);
      }
    }
  }

  function morphNode(old, incoming) {
    if (old.nodeType !== 1) {
      if (old.data !== incoming.data) old.data = incoming.data;
      return;
    }
    if (old.isEqualNode(incoming)) return;
    syncAttributes(old, incoming);
    if (old.hasAttribute("data-live-ignore")) return;
    if (old.nodeName === "TEXTAREA") {
      const text = incoming.textContent;
      if (old.defaultValue !== text) {
        old.textContent = text;
        if (!ahead(old)) old.value = text;
      }
      return;
    }
    morphRange(old, old.firstChild, null, incoming);
  }

  // Make the siblings from `start` up to (not including) `end` match the
  // children of `source`, reusing what is there.
  function morphRange(parent, start, end, source) {
    const keyed = new Map();
    for (let node = start; node && node !== end; node = node.nextSibling) {
      const key = keyOf(node);
      if (key) keyed.set(key, node);
    }
    const wanted = new Set();
    for (let node = source.firstChild; node; node = node.nextSibling) {
      const key = keyOf(node);
      if (key) wanted.add(key);
    }
    const spoken = (node) => { const key = keyOf(node); return key !== null && wanted.has(key); };

    let cursor = start;
    let next = source.firstChild;
    while (next) {
      const incoming = next;
      next = next.nextSibling;
      const key = keyOf(incoming);
      let match = null;

      if (key) {
        // Same key means same thing, wherever it has got to.
        const candidate = keyed.get(key);
        if (candidate && candidate.nodeName === incoming.nodeName) {
          match = candidate;
          keyed.delete(key);
        }
      } else {
        // Otherwise take the next node that can become this one, dropping
        // what stands in the way unless a later key is going to ask for it.
        let probe = cursor;
        while (probe && probe !== end && !(compatible(probe, incoming) && !spoken(probe))) {
          if (spoken(probe)) { probe = null; break; }
          probe = probe.nextSibling;
        }
        if (probe && probe !== end) {
          while (cursor !== probe) {
            const drop = cursor;
            cursor = cursor.nextSibling;
            parent.removeChild(drop);
          }
          match = probe;
        }
      }

      if (!match) {
        parent.insertBefore(incoming, cursor);
        continue;
      }
      if (match === cursor) {
        cursor = cursor.nextSibling;
      } else if (parent.moveBefore) {
        parent.moveBefore(match, cursor); // keeps focus and running media
      } else {
        parent.insertBefore(match, cursor);
      }
      morphNode(match, incoming);
    }

    while (cursor && cursor !== end) {
      const drop = cursor;
      cursor = cursor.nextSibling;
      parent.removeChild(drop);
    }
  }

  function parse(html, parent) {
    const template = document.createElement("template");
    if (parent.namespaceURI === SVG && parent.localName !== "foreignObject") {
      template.innerHTML = "<svg>" + html + "</svg>";
      return template.content.firstChild;
    }
    template.innerHTML = html;
    return template.content;
  }

  // Moving a node can cost it the focus even though it never left the page.
  function keepingFocus(work) {
    const active = document.activeElement;
    let selection = null;
    try {
      if (active && typeof active.selectionStart === "number") {
        selection = [active.selectionStart, active.selectionEnd];
      }
    } catch (_) { /* some input types have no selection */ }
    work();
    if (active && active !== document.body && active.isConnected && document.activeElement !== active) {
      active.focus({ preventScroll: true });
      if (selection) {
        try { active.setSelectionRange(selection[0], selection[1]); } catch (_) { /* as above */ }
      }
    }
  }

  // --------------------------------------------------------------- patches

  function applyPatch(patch) {
    if (patch.r !== undefined) {
      const id = String(patch.r);
      const start = regionStart(id);
      if (!start) return; // replaced by an outer patch already
      let end = start.nextSibling;
      while (end && !(end.nodeType === 8 && end.data === "]" + id)) end = end.nextSibling;
      if (!end) return;
      morphRange(start.parentNode, start.nextSibling, end, parse(patch.h, start.parentNode));
    } else if (patch.a !== undefined) {
      const el = elementFor(String(patch.a));
      if (!el) return;
      const value = patch.v === undefined ? null : patch.v;
      if (value === null) el.removeAttribute(patch.n);
      else el.setAttribute(patch.n, value);
      setProperty(el, patch.n, value);
    } else if (patch.x !== undefined) {
      const el = elementFor(String(patch.x));
      if (!el) return;
      const text = patch.v === undefined ? "" : patch.v;
      el.textContent = text;
      if (el.nodeName === "TEXTAREA" && !ahead(el)) el.value = text;
    }
  }

  // The whole page again, after a gap in the connection.
  function resync(html) {
    const fresh = new DOMParser().parseFromString(html, "text/html");
    if (fresh.title !== document.title) document.title = fresh.title;
    syncAttributes(root, fresh.documentElement);
    for (const node of fresh.head.querySelectorAll("[data-l]")) {
      const el = elementFor(node.getAttribute("data-l"));
      if (el) syncAttributes(el, node);
    }
    syncAttributes(document.body, fresh.body);
    morphRange(document.body, document.body.firstChild, null, fresh.body);
    regions.clear();
    elements.clear();
  }

  // ---------------------------------------------------------------- events

  const EVENTS = {
    click: "click", dblclick: "dblclick", input: "input", change: "change",
    submit: "submit", keydown: "keydown", keyup: "keyup",
    focusin: "focus", focusout: "blur",
  };

  function post(message) {
    const text = JSON.stringify(message);
    if (socket && socket.readyState === 1) socket.send(text);
    else backlog.push(text);
  }

  function transmit(el, source, name, event) {
    const detail = { type: name };
    if (el instanceof HTMLFormElement) {
      detail.form = {};
      let data;
      try { data = new FormData(el, event.submitter); } catch (_) { data = new FormData(el); }
      for (const [field, value] of data) {
        if (typeof value === "string") detail.form[field] = value;
      }
    }
    if (source !== el || !(el instanceof HTMLFormElement)) {
      if (typeof source.value === "string") detail.value = source.value;
      if (typeof source.name === "string" && source.name) detail.name = source.name;
      if (source.type === "checkbox" || source.type === "radio") detail.checked = source.checked;
    }
    if (name === "keydown" || name === "keyup") {
      detail.key = event.key;
      if (event.ctrlKey) detail.ctrl = true;
      if (event.shiftKey) detail.shift = true;
      if (event.altKey) detail.alt = true;
      if (event.metaKey) detail.meta = true;
    }

    // Cleared now, not when the server answers: by then the person may
    // have started on the next thing, and that must not be wiped.
    if (name === "submit" && el.hasAttribute("data-reset")) el.reset();

    const number = ++sequence;
    if (detail.value !== undefined) (source._sent || (source._sent = [])).push(detail.value);
    waiting.set(number, { el, source, value: detail.value });
    el.setAttribute("aria-busy", "true");
    post({ t: "e", h: Number(el.getAttribute("data-on-" + name)), n: number, d: detail });
  }

  // Anything held back for debouncing goes first, so the server never sees
  // a submit before the typing that led up to it.
  function flushTimers() {
    for (const [, pending] of timers) {
      clearTimeout(pending.timer);
      pending.send();
    }
    timers.clear();
  }

  function onEvent(event, name) {
    let target = event.target;
    if (target && target.nodeType !== 1) target = target.parentElement;
    if (!target || !target.closest) return;
    const el = target.closest("[data-on-" + name + "]");
    if (!el) return;

    if (name === "keydown" || name === "keyup") {
      const keys = el.getAttribute("data-keys");
      if (keys && !keys.split(" ").includes(event.key)) return;
    }
    const deliberate = name === "click" || name === "submit";
    if (name === "submit" || (name === "click" && el.nodeName === "A")) event.preventDefault();
    if (deliberate) {
      if (el.getAttribute("aria-busy") === "true") return; // already on its way
      const question = el.getAttribute("data-confirm");
      if (question && !window.confirm(question)) return;
    }

    // The value belongs to whatever was typed into, which is not always
    // the element listening: a form may listen for all of its fields.
    const source = "value" in el ? el : target;
    const send = () => transmit(el, source, name, event);
    const configured = Number(el.getAttribute("data-debounce"));
    const wait = Number.isFinite(configured) && el.hasAttribute("data-debounce") ? configured : name === "input" ? 150 : 0;
    if (wait > 0) {
      const pending = timers.get(source);
      if (pending) clearTimeout(pending.timer);
      timers.set(source, {
        send,
        timer: setTimeout(() => { timers.delete(source); send(); }, wait),
      });
    } else {
      flushTimers();
      send();
    }
  }

  // `outcome` is "ok", "failed", or "dropped" when the socket closed first
  // and nothing is known about what the server did.
  function settle(number, outcome, message) {
    const entry = waiting.get(number);
    if (!entry) return;
    waiting.delete(number);
    const { el, source, value } = entry;
    if (source._sent) {
      const at = source._sent.indexOf(value);
      if (at !== -1) source._sent.splice(at, 1);
    }
    let stillBusy = false;
    for (const other of waiting.values()) stillBusy = stillBusy || other.el === el;
    if (!stillBusy) el.removeAttribute("aria-busy");
    if (outcome === "failed") {
      console.error("live: the server could not handle an event" + (message ? "\n" + message : ""));
      el.dispatchEvent(new CustomEvent("live:error", { bubbles: true, detail: { message: message || null } }));
    }
  }

  // ------------------------------------------------------------ navigation
  //
  // On a page with routes, a link to somewhere on this site is not followed
  // by the browser. The server is asked instead, and either swaps the page's
  // content in place or says the URL is not one of its own, in which case it
  // is loaded the ordinary way.

  function visit(url, el, pop) {
    flushTimers();
    const number = ++sequence;
    const message = { t: "nav", u: url, n: number };
    if (pop) message.pop = true;
    if (el) {
      waiting.set(number, { el, source: el, value: undefined });
      el.setAttribute("aria-busy", "true");
    }
    post(message);
  }

  // After a move: go to the anchor if the URL names one, else to the top.
  function arrive() {
    const id = decodeURIComponent(location.hash.slice(1));
    const anchor = id && document.getElementById(id);
    if (anchor) anchor.scrollIntoView();
    else window.scrollTo(0, 0);
  }

  function onLinkClick(event) {
    if (event.defaultPrevented || event.button !== 0) return;
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    let target = event.target;
    if (target && target.nodeType !== 1) target = target.parentElement;
    const link = target && target.closest ? target.closest("a[href]") : null;
    if (!link) return;
    // Left to the browser: new windows, downloads, other sites, and any
    // link marked as leaving the page.
    if (link.target && link.target !== "_self") return;
    if (link.hasAttribute("download") || link.hasAttribute("data-reload")) return;
    if ((link.getAttribute("rel") || "").split(/\s+/).includes("external")) return;
    if (link.origin !== location.origin) return;
    // Same page, different anchor: that is a scroll, not a navigation.
    if (link.pathname === location.pathname && link.search === location.search && link.hash) return;
    // With no connection there is nobody to ask. Let the browser load the
    // link, which works even if the server has restarted in the meantime.
    if (!socket || socket.readyState !== 1) return;
    event.preventDefault();
    if (link.getAttribute("aria-busy") === "true") return;
    visit(link.pathname + link.search + link.hash, link, false);
  }

  if (routed) {
    document.addEventListener("click", onLinkClick);
    addEventListener("popstate", () => {
      if (socket && socket.readyState === 1) visit(location.pathname + location.search, null, true);
      else location.reload();
    });
  }

  // ------------------------------------------------------------ connection

  function receive(message) {
    switch (message.t) {
      case "p":
        keepingFocus(() => { for (const patch of message.p) applyPatch(patch); });
        document.dispatchEvent(new CustomEvent("live:update"));
        break;
      case "ack":
        settle(message.n, message.ok === false ? "failed" : "ok", message.m);
        break;
      case "sync":
        keepingFocus(() => resync(message.h));
        document.dispatchEvent(new CustomEvent("live:update"));
        break;
      case "go":
        if (message.r) location.replace(message.u);
        else location.assign(message.u);
        break;
      case "url":
        // The server has moved this page to another of its own URLs.
        if (message.r) history.replaceState({}, "", message.u);
        else history.pushState({}, "", message.u);
        arrive();
        break;
      case "reload":
        location.reload();
        break;
      case "ev":
        document.dispatchEvent(new CustomEvent(message.n, { detail: message.d === undefined ? null : message.d }));
        break;
      case "gone":
        restart();
        break;
    }
  }

  // The server no longer has this page (it restarted, or the page sat
  // unconnected too long). Load it again, but not in a loop.
  function restart() {
    leaving = true;
    let last = 0;
    try { last = Number(sessionStorage.getItem("live:restart")) || 0; } catch (_) { /* storage blocked */ }
    if (Date.now() - last < 5000) {
      setState("off");
      return;
    }
    try { sessionStorage.setItem("live:restart", String(Date.now())); } catch (_) { /* as above */ }
    location.reload();
  }

  function connect() {
    if (leaving) return;
    setState("connecting");
    const scheme = location.protocol === "https:" ? "wss://" : "ws://";
    socket = new WebSocket(scheme + location.host + socketPath);
    socket.onopen = () => {
      attempt = 0;
      socket.send(JSON.stringify({ t: "hello", m: mountId }));
      setState("on");
      for (const text of backlog.splice(0)) socket.send(text);
    };
    socket.onmessage = (event) => {
      let message;
      try { message = JSON.parse(event.data); } catch (_) { return; }
      receive(message);
    };
    socket.onclose = () => {
      socket = null;
      // No acknowledgement is coming for anything sent on this socket.
      for (const number of Array.from(waiting.keys())) settle(number, "dropped");
      if (leaving) return;
      setState("off");
      setTimeout(connect, Math.min(5000, 250 * 2 ** attempt++));
    };
  }

  for (const [type, name] of Object.entries(EVENTS)) {
    document.addEventListener(type, (event) => onEvent(event, name), true);
  }

  // Proxies close sockets that say nothing for a while.
  setInterval(() => { if (socket && socket.readyState === 1) socket.send('{"t":"ping"}'); }, 25000);

  addEventListener("pagehide", () => {
    leaving = true;
    if (socket && socket.readyState === 1) {
      socket.send('{"t":"bye"}');
      socket.close();
    }
  });
  // Restored from the back/forward cache: the server let go of this page
  // when it was left, so build a new one.
  addEventListener("pageshow", (event) => { if (event.persisted) location.reload(); });

  connect();
})();
