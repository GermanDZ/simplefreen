// Hash-based router. Hash URLs avoid coupling to server-side
// routing — simplefreen serves a single index.html and lets the
// client decide which view is on screen.
//
// Routes are declared with id + match (string or RegExp) + handlers:
//
//   register({
//     id: "profile-detail",
//     match: /^#\/profiles\/([^/]+)$/,
//     onEnter: (params) => { ... },
//     onLeave: () => { ... }
//   })
//
// The first matching route wins; an explicit default route can be
// registered with match: "*" and is used when nothing else matches.
//
// Views in this codebase live inside the existing index.html as
// <section class="route-view" data-route-view="id"> blocks. The
// router only toggles visibility — it does not unmount markup —
// so existing event listeners attached at page load survive
// navigation. This is the pragmatic choice for an admin UI where
// every view shares the same long-lived state poller.

const routes = [];
const subscribers = new Set();
let current = null;

export function register(route) {
  if (!route || !route.id) throw new Error("router: route needs an id");
  routes.push(route);
}

export function start() {
  window.addEventListener("hashchange", resolve);
  resolve();
}

export function navigate(hash) {
  if (!hash.startsWith("#")) hash = "#" + hash;
  if (window.location.hash === hash) {
    resolve();
    return;
  }
  window.location.hash = hash;
}

export function currentRoute() {
  return current;
}

export function onChange(fn) {
  subscribers.add(fn);
  try { fn(current); } catch (e) { console.error("[router] subscriber threw:", e); }
  return () => subscribers.delete(fn);
}

function resolve() {
  const hash = window.location.hash || "#/";
  let match = null;
  let params = null;

  for (const r of routes) {
    if (r.match === "*") {
      if (!match) { match = r; params = {}; }
      continue;
    }
    if (typeof r.match === "string") {
      if (r.match === hash) { match = r; params = {}; break; }
    } else if (r.match instanceof RegExp) {
      const m = hash.match(r.match);
      if (m) { match = r; params = m.slice(1); break; }
    }
  }

  if (!match) return;

  if (current && current.id !== match.id && current.onLeave) {
    try { current.onLeave(); }
    catch (e) { console.error(`[router] onLeave "${current.id}" threw:`, e); }
  }

  toggleViewVisibility(match.id);
  current = match;

  if (match.onEnter) {
    try { match.onEnter(params || {}); }
    catch (e) { console.error(`[router] onEnter "${match.id}" threw:`, e); }
  }

  for (const fn of subscribers) {
    try { fn(current); }
    catch (e) { console.error("[router] subscriber threw:", e); }
  }
}

function toggleViewVisibility(activeId) {
  document.querySelectorAll(".route-view").forEach((node) => {
    const viewId = node.getAttribute("data-route-view");
    if (viewId === activeId) node.removeAttribute("hidden");
    else node.setAttribute("hidden", "");
  });

  document.querySelectorAll("[data-route-link]").forEach((node) => {
    const target = node.getAttribute("data-route-link");
    if (target === activeId) node.setAttribute("aria-current", "page");
    else node.removeAttribute("aria-current");
  });
}
