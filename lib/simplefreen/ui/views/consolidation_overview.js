// Consolidation page overview — sits at the top of the
// /admin/#/consolidation route. Aggregates the slow-cadence
// loaders' results into a single at-a-glance strip + jump pills
// so operators don't have to scroll the whole page to know
// what's going on.
//
// Reads three store slices populated by the existing loaders
// (loadConsolidation, loadVirtualProfile, loadExportPreview);
// no new backend.

import { el } from "../lib/dom.js";
import { subscribe } from "../lib/store.js";

let mounted = false;
const slice = { consolidation: null, virtualProfile: null, exportPreview: null };

export function mount() {
  if (mounted) return;
  mounted = true;
  subscribe("consolidation",   (v) => { slice.consolidation = v;   render(); });
  subscribe("virtualProfile",  (v) => { slice.virtualProfile = v;  render(); });
  subscribe("exportPreview",   (v) => { slice.exportPreview = v;   render(); });
}

function render() {
  const root = document.getElementById("consolidation-overview-body");
  if (!root) return;

  const cons = slice.consolidation;
  const vp   = slice.virtualProfile;
  const exp  = slice.exportPreview;

  const linked       = cons ? (cons.groups || []).filter((g) => g.sources.length > 1).length : 0;
  const sources      = cons ? (cons.profile_count || 0) : 0;
  const aliases      = cons ? (cons.alias_count || 0) : 0;
  const suggestions  = cons ? (cons.suggestions || []).length : 0;

  const vpState      = vp && vp.virtual_profile ? vp.virtual_profile.state : null;
  const vpWarnings   = vp ? (vp.warnings || []).length : 0;

  const expAccounts  = exp ? (exp.accounts || []).length : 0;
  const expTotalTxns = exp ? (exp.accounts || []).reduce((n, a) => n + (a.txn_count_total || 0), 0) : 0;
  const expWarnings  = exp ? (exp.warnings || []).length : 0;
  const expHidden    = exp ? (exp.hidden_suppressions || []).length : 0;

  const totalWarnings = vpWarnings + expWarnings;

  root.replaceChildren(
    el("div", { class: "consolidation-stats" },
      statCard(
        "linked accounts",
        String(linked),
        sources ? `across ${sources} source${sources === 1 ? "" : "s"}` : "no sources yet",
        suggestions ? `${suggestions} suggestion${suggestions === 1 ? "" : "s"} waiting` : null,
        "#consolidation-panel",
      ),
      statCard(
        "consolidated profile",
        vpState === "ready" ? "ready" : "pending",
        vpState === "ready"
          ? `${aliases} alias${aliases === 1 ? "" : "es"}`
          : "not set up yet",
        vpWarnings ? `${vpWarnings} warning${vpWarnings === 1 ? "" : "s"}` : null,
        "#virtual-profile-panel",
        vpState === "ready" ? "success" : "neutral",
      ),
      statCard(
        "exported",
        String(expAccounts),
        expTotalTxns ? `${expTotalTxns.toLocaleString()} transactions` : "no data yet",
        expHidden ? `${expHidden} hidden` : null,
        "#export-preview-panel",
      ),
    ),
    totalWarnings ? el("p", { class: "consolidation-overview-warn" },
      el("strong", {}, "⚠ "), `${totalWarnings} active warning${totalWarnings === 1 ? "" : "s"} below. `,
      el("a", { href: "#virtual-profile-panel", onclick: scrollToAnchor }, "Jump to virtual profile"),
      vpWarnings && expWarnings ? " · " : null,
      expWarnings ? el("a", { href: "#export-preview-panel", onclick: scrollToAnchor }, "Jump to export preview") : null,
    ) : null,
  );
}

function statCard(label, value, sub, extra, anchor, kind) {
  const attrs = { class: "consolidation-stat" };
  if (anchor) {
    attrs.href = anchor;
    attrs.onclick = scrollToAnchor;
  }
  const valueClass = kind === "success" ? "consolidation-stat-value success" : "consolidation-stat-value";
  return el(anchor ? "a" : "div", attrs,
    el("div", { class: "consolidation-stat-label" }, label),
    el("div", { class: valueClass }, value),
    el("div", { class: "consolidation-stat-sub" }, sub || ""),
    extra ? el("div", { class: "consolidation-stat-extra" }, extra) : null,
  );
}

function scrollToAnchor(ev) {
  ev.preventDefault();
  const id = ev.currentTarget.getAttribute("href").slice(1);
  const node = document.getElementById(id);
  if (!node) return;
  node.scrollIntoView({ behavior: "smooth", block: "start" });
}
