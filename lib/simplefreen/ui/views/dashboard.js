// Dashboard — the "what's going on right now" surface. Pure
// subscriber: reads from the store keys populated by the existing
// polling loaders (profiles, activeJob, freentonicHealth,
// consolidation, virtualProfile) and re-renders on each change.
//
// No backend work: every datum below is already on /admin/api/status
// or one of the slower-cadence loaders. This view is the
// aggregation, not a new endpoint.

import { el } from "../lib/dom.js";
import { subscribe } from "../lib/store.js";
import { timeAgo } from "../lib/format.js";

const STATE_ORDER = ["running", "queued", "needs_reauth", "error", "ready", "idle", "browsed"];
const ATTENTION_STATES = new Set(["needs_reauth", "error"]);

let mounted = false;
const slice = {
  profiles: [],
  activeJob: null,
  queuePending: [],
  freentonicHealth: null,
  consolidation: null,
  virtualProfile: null,
};

export function mount() {
  if (mounted) return;
  mounted = true;

  subscribe("profiles",         (v) => { slice.profiles = v || []; render(); });
  subscribe("activeJob",        (v) => { slice.activeJob = v; render(); });
  subscribe("queuePending",     (v) => { slice.queuePending = v || []; render(); });
  subscribe("freentonicHealth", (v) => { slice.freentonicHealth = v; render(); });
  subscribe("consolidation",    (v) => { slice.consolidation = v; render(); });
  subscribe("virtualProfile",   (v) => { slice.virtualProfile = v; render(); });
}

function render() {
  const root = document.getElementById("dashboard-body");
  if (!root) return;
  // Don't paint until the first /admin/api/status reply lands —
  // avoids a flash of "0 profiles" before the poll resolves.
  if (slice.profiles === undefined) return;

  root.replaceChildren(
    renderActiveJobBanner(),
    renderGlance(),
    renderAttention(),
    renderRecent(),
  );
}

// The dashboard talks about *source* profiles — banks you sync.
// The "consolidated" virtual profile is summarized separately in
// its own stat card, so filter it out of every list below.
function sourceProfiles() {
  return (slice.profiles || []).filter((p) => p.kind !== "virtual");
}

function renderGlance() {
  const profiles = sourceProfiles();
  const stateCounts = countByState(profiles);
  const total = profiles.length;
  const fh = slice.freentonicHealth;
  const cons = slice.consolidation;
  const vp = slice.virtualProfile;

  const cards = [];

  cards.push(statCard(
    "freentonic",
    fh ? fh.state : "unknown",
    fh && fh.last_probe_at ? `probed ${timeAgo(fh.last_probe_at)}` : "no probe yet",
    fh ? `health-state health-${fh.state}` : "health-state health-unknown",
  ));

  cards.push(statCard(
    "profiles",
    String(total),
    total === 0
      ? "no profiles configured yet"
      : STATE_ORDER
          .filter((s) => stateCounts[s])
          .map((s) => `${stateCounts[s]} ${s.replaceAll("_", " ")}`)
          .join(" · "),
  ));

  if (cons) {
    const linked = (cons.groups || []).filter((g) => g.sources.length > 1).length;
    const sug = (cons.suggestions || []).length;
    cards.push(statCard(
      "linked accounts",
      String(linked),
      sug ? `${sug} suggestion${sug === 1 ? "" : "s"} waiting` : "no pending suggestions",
      "",
      "#/consolidation",
    ));
  }

  if (vp) {
    const ready = vp.virtual_profile && vp.virtual_profile.state === "ready";
    cards.push(statCard(
      "consolidated profile",
      ready ? "ready" : "pending",
      ready ? "single SimpleFIN URL is live" : "not yet set up",
      "",
      "#/consolidation",
    ));
  }

  return el("section", { class: "panel dashboard-glance" },
    el("h2", {}, "At a glance"),
    el("div", { class: "stat-grid" }, ...cards),
  );
}

function statCard(label, value, sub, valueClass, href) {
  const tag = href ? "a" : "div";
  const attrs = { class: "stat-card" };
  if (href) attrs.href = href;
  return el(tag, attrs,
    el("div", { class: "stat-label" }, label),
    el("div", { class: `stat-value ${valueClass || ""}` }, value),
    el("div", { class: "stat-sub" }, sub || ""),
  );
}

function renderAttention() {
  const profiles = sourceProfiles();
  const needs = profiles.filter((p) => ATTENTION_STATES.has(p.state) || p.last_error);
  const panel = el("section", { class: "panel dashboard-attention" },
    el("h2", {}, "Needs attention"),
  );
  if (!needs.length) {
    panel.appendChild(el("p", { class: "sub" }, "Everything looks healthy."));
    return panel;
  }
  const list = el("ul", { class: "attention-list" });
  needs.forEach((p) => {
    list.appendChild(el("li", { class: "attention-row" },
      el("span", { class: `state-pill state-${p.state}` }, p.state.replaceAll("_", " ")),
      el("strong", {}, p.display_name || p.profile_key),
      p.last_error ? el("span", { class: "attention-error" }, p.last_error) : null,
      el("a", {
        class: "attention-link",
        href: "#/manage",
        title: "Open the manage view to act on this profile",
      }, "Manage →"),
    ));
  });
  panel.appendChild(list);
  return panel;
}

function renderRecent() {
  const profiles = sourceProfiles();
  const synced = profiles
    .filter((p) => p.last_synced_at)
    .sort((a, b) => Date.parse(b.last_synced_at) - Date.parse(a.last_synced_at))
    .slice(0, 5);

  const panel = el("section", { class: "panel dashboard-recent" },
    el("h2", {}, "Recent syncs"),
  );
  if (!synced.length) {
    panel.appendChild(el("p", { class: "sub" }, "No syncs have completed yet."));
    return panel;
  }
  const list = el("ul", { class: "recent-list" });
  synced.forEach((p) => {
    list.appendChild(el("li", { class: "recent-row" },
      el("strong", {}, p.display_name || p.profile_key),
      el("span", { class: `state-pill state-${p.state}` }, p.state.replaceAll("_", " ")),
      el("span", { class: "recent-when" }, timeAgo(p.last_synced_at)),
    ));
  });
  panel.appendChild(list);
  return panel;
}

function renderActiveJobBanner() {
  const job = slice.activeJob;
  const pending = slice.queuePending || [];
  if (!job && pending.length === 0) return el("div", { hidden: "" });

  const rows = [];
  if (job) {
    rows.push(el("div", { class: "active-job-row" },
      el("span", { class: "state-pill state-running" }, "running"),
      el("strong", {}, job.profile_key || job.profile || "active job"),
      el("a", { class: "attention-link", href: "#/manage" }, "Open →"),
    ));
  }
  if (pending.length) {
    const pills = pending.map((k) =>
      el("a", { class: "state-pill state-queued queue-pill", href: `#/profiles/${encodeURIComponent(k)}` }, k)
    );
    rows.push(el("div", { class: "active-job-row" },
      el("span", { class: "queue-label" }, `Queued (${pending.length}):`),
      ...pills,
    ));
  }
  return el("section", { class: "panel dashboard-active-job" }, ...rows);
}

function countByState(profiles) {
  const out = {};
  for (const p of profiles) out[p.state] = (out[p.state] || 0) + 1;
  return out;
}
