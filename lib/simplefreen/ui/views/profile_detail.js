// Profile detail — focused per-profile workspace at
// #/profiles/:key. Two-slot layout so heavy stateful UI in the
// runs section (expanded logs, canonical viewer tabs, artifact
// gallery, recording transcripts) isn't wiped on every 2 s status
// poll:
//
//   #profile-detail-upper  — header, overview, actions, danger
//                            zone. Rebuilt on every store update.
//   #profile-detail-runs   — full per-run UI rendered via the
//                            shared renderRun pipeline owned by
//                            app.js (passed in as onLoadRuns).
//                            Built once on enter; explicit reload
//                            button refreshes it on demand.

import { el } from "../lib/dom.js";
import { getState, subscribe } from "../lib/store.js";
import { lookbackLabel, historyLabel, formatInterval, timeAgo } from "../lib/format.js";

let currentKey = null;
let actions    = {};
let mounted    = false;

// The Schedule panel owns a <select> that survives across the 2 s
// status poll only if we don't detach/re-attach it. Even an
// element-identity-preserving rebuild via replaceChildren resets the
// browser's chosen <option> back to whichever has the `selected`
// attribute. So we render the Schedule panel into its own slot ONCE
// per profile-enter (mirrors the runs slot below) and let renderUpper
// rebuild only the surrounding panels on each poll. The schedule
// panel is rebuilt only when (a) entering a different profile, or
// (b) the persisted sync_interval_seconds actually changes.
let scheduleSlotValue = undefined;
let scheduleSlotKey   = null;

export function configure(handlers) {
  actions = handlers || {};
}

export function mount() {
  if (mounted) return;
  mounted = true;
  subscribe("profiles", () => {
    if (currentKey != null) {
      renderUpper();
      maybeRebuildSchedule();
    }
  });
}

export function enter(key) {
  currentKey = key;
  scheduleSlotKey = null;
  scheduleSlotValue = undefined;
  renderUpper();
  rebuildScheduleSlot();
  setupRunsSlot(key);
}

export function leave() {
  currentKey = null;
  scheduleSlotKey = null;
  scheduleSlotValue = undefined;
  const slot = document.getElementById("profile-detail-runs");
  if (slot) slot.innerHTML = "";
  const sched = document.getElementById("profile-detail-schedule");
  if (sched) sched.innerHTML = "";
}

// Rebuild the Schedule slot only when (a) the active profile changed,
// or (b) the persisted sync_interval_seconds for the current profile
// changed. Otherwise leave the live <select> alone so a half-finished
// pick survives the 2 s status poll.
function maybeRebuildSchedule() {
  if (!currentKey) return;
  const profiles = getState("profiles") || [];
  const p = profiles.find((x) => x.profile_key === currentKey);
  if (!p || p.kind === "virtual") return;
  const current = p.sync_interval_seconds || null;
  if (scheduleSlotKey === p.profile_key && scheduleSlotValue === current) return;
  rebuildScheduleSlot();
}

function rebuildScheduleSlot() {
  const slot = document.getElementById("profile-detail-schedule");
  if (!slot) return;
  if (!currentKey) { slot.innerHTML = ""; return; }
  const profiles = getState("profiles") || [];
  const p = profiles.find((x) => x.profile_key === currentKey);
  if (!p || p.kind === "virtual") { slot.innerHTML = ""; return; }
  const current = p.sync_interval_seconds || null;
  slot.replaceChildren(buildSchedulePanel(p, current));
  scheduleSlotKey = p.profile_key;
  scheduleSlotValue = current;
}

function renderUpper() {
  const root = document.getElementById("profile-detail-upper");
  if (!root) return;

  if (!currentKey) {
    root.replaceChildren(el("p", { class: "sub" }, "No profile selected."));
    return;
  }

  const profiles = getState("profiles") || [];
  const p = profiles.find((x) => x.profile_key === currentKey);

  if (!p) {
    root.replaceChildren(
      el("section", { class: "panel" },
        el("h2", {}, "Profile not found"),
        el("p", { class: "sub" },
          "No profile with key ", el("code", {}, currentKey), " exists. ",
          "It may have been deleted, or the URL is stale."
        ),
        el("a", { class: "button-link", href: "#/manage" }, "Back to list"),
      ),
    );
    return;
  }

  // The "consolidated" virtual profile has no workflow/credentials/
  // sync — none of the detail-page actions apply. Bounce to the
  // Consolidation page where it's properly managed.
  if (p.kind === "virtual") {
    root.replaceChildren(
      el("section", { class: "panel" },
        el("h2", {}, "Managed on the Consolidation page"),
        el("p", { class: "sub" },
          "The ", el("code", {}, p.profile_key),
          " profile is the virtual anchor for the merged SimpleFIN feed. ",
          "It has no workflow, no credentials, and isn't synced like a bank source — ",
          "you configure its groups, windows, and setup token from the Consolidation view."
        ),
        el("a", { class: "button-link", href: "#/consolidation" }, "Go to Consolidation"),
      ),
    );
    return;
  }

  root.replaceChildren(
    renderHeader(p),
    renderOverviewPanel(p),
    renderActionsPanel(p),
    renderDangerZone(p),
  );
}

function setupRunsSlot(key) {
  const slot = document.getElementById("profile-detail-runs");
  if (!slot) return;
  slot.innerHTML = "";
  if (!key) return;

  // Don't render the runs section for the virtual "consolidated"
  // profile — it has no runs.
  const profiles = getState("profiles") || [];
  const p = profiles.find((x) => x.profile_key === key);
  if (!p || p.kind === "virtual") return;

  // The runs-panel container is what the shared renderRun pipeline
  // (in app.js) writes into. CSS selectors keyed on
  // [data-runs-for="<key>"] already exist for this shape.
  const runsTarget = el("div", {
    class: "runs-panel",
    "data-runs-for": key,
    id: "detail-runs-container",
  });

  const reloadBtn = el("button", {
    type: "button",
    class: "detail-runs-reload",
    title: "Re-fetch the runs list (a sync in flight will surface here once it completes).",
    onclick: () => reloadRuns(),
  }, "↻ Reload");

  const panel = el("section", { class: "panel" },
    el("div", { class: "panel-head" },
      el("h2", {}, "Runs"),
      reloadBtn,
    ),
    runsTarget,
  );
  slot.appendChild(panel);

  reloadRuns();
}

function reloadRuns() {
  if (!currentKey || !actions.onLoadRuns) return;
  const target = document.getElementById("detail-runs-container");
  if (!target) return;
  Promise.resolve(actions.onLoadRuns(target, currentKey))
    .catch((e) => console.error("[profile_detail] onLoadRuns failed:", e));
}

function renderHeader(p) {
  return el("div", { class: "detail-header" },
    el("a", { class: "detail-back", href: "#/manage" }, "← Back to list"),
    el("h2", { class: "detail-title" }, p.display_name || p.profile_key),
    el("span", { class: `state-pill state-${p.state}` }, p.state.replaceAll("_", " ")),
    el("span", { class: "detail-key" }, p.profile_key),
  );
}

function renderOverviewPanel(p) {
  const items = [
    metaItem("Workflow",           p.workflow.replace(/\/workflow\.yml$/, "")),
    metaItem("Lookback",           lookbackLabel(p)),
    metaItem("History",            historyLabel(p)),
    metaItem("Last synced",        p.last_synced_at ? timeAgo(p.last_synced_at) : "never"),
    metaItem("Auto-sync",          p.sync_interval_seconds ? `every ${formatInterval(p.sync_interval_seconds)}` : "disabled"),
    metaItem("Access URL",         p.access_url_configured ? "configured ✓" : "pending"),
    metaItem("Secrets",            p.credential_names.length ? `${p.credential_names.length} stored` : "none"),
    p.hidden_accounts && p.hidden_accounts.length
      ? metaItem("Hidden accounts", `${p.hidden_accounts.length}`)
      : null,
  ].filter(Boolean);

  const panel = el("section", { class: "panel" },
    el("h2", {}, "Overview"),
    el("div", { class: "detail-meta" }, ...items),
  );

  if (p.last_error) {
    panel.appendChild(el("p", { class: "sub", style: "color: var(--state-error-fg)" },
      "Last error: ", p.last_error));
  }

  return panel;
}

function metaItem(label, value) {
  return el("div", { class: "detail-meta-item" },
    el("div", { class: "detail-meta-label" }, label),
    el("div", { class: "detail-meta-value" }, value || "—"),
  );
}

// Common presets (in seconds). `null` means manual-only — clearing the
// auto-sync interval on the backend. The custom row lets the operator
// dial in anything ≥ 300 (the backend floor).
const SCHEDULE_PRESETS = [
  { label: "Manual only",  value: null     },
  { label: "Every 15 min", value: 900      },
  { label: "Every 30 min", value: 1800     },
  { label: "Hourly",       value: 3600     },
  { label: "Every 3 h",    value: 10800    },
  { label: "Every 6 h",    value: 21600    },
  { label: "Every 12 h",   value: 43200    },
  { label: "Daily",        value: 86400    },
];

function buildSchedulePanel(p, current) {
  const matchedPreset = SCHEDULE_PRESETS.find((s) => s.value === current);
  const isCustom = current != null && !matchedPreset;

  const select = el("select", { class: "schedule-preset" });
  SCHEDULE_PRESETS.forEach((s) => {
    const opt = el("option", { value: s.value == null ? "" : String(s.value) }, s.label);
    if (s.value === current) opt.setAttribute("selected", "");
    select.appendChild(opt);
  });
  const customOpt = el("option", { value: "custom" }, "Custom (seconds)…");
  if (isCustom) customOpt.setAttribute("selected", "");
  select.appendChild(customOpt);

  const customInput = el("input", {
    type: "number",
    min: "300",
    step: "60",
    placeholder: "seconds (min 300)",
    class: "schedule-custom",
    value: isCustom ? String(current) : "",
  });
  customInput.hidden = !isCustom;

  const status = el("span", { class: "sub schedule-status" });
  const saveBtn = el("button", { type: "button", class: "primary" }, "Save");

  select.addEventListener("change", () => {
    customInput.hidden = select.value !== "custom";
    status.textContent = "";
    if (select.value === "custom") customInput.focus();
  });

  saveBtn.addEventListener("click", async () => {
    let nextValue;
    if (select.value === "") {
      nextValue = null;
    } else if (select.value === "custom") {
      const raw = customInput.value.trim();
      if (raw === "") {
        status.textContent = "Enter a custom interval in seconds (min 300), or pick Manual only.";
        return;
      }
      const n = parseInt(raw, 10);
      if (!Number.isFinite(n) || n < 300) {
        status.textContent = "Custom interval must be an integer ≥ 300 seconds (5 min).";
        return;
      }
      nextValue = n;
    } else {
      nextValue = parseInt(select.value, 10);
    }
    status.textContent = "saving…";
    try {
      await (actions.onSaveSchedule
        ? actions.onSaveSchedule(p.profile_key, nextValue)
        : Promise.reject(new Error("save handler missing")));
      status.textContent = nextValue ? `saved — auto-sync ${formatInterval(nextValue)}` : "saved — manual only";
    } catch (e) {
      status.textContent = `save failed: ${e.message}`;
    }
  });

  const nextDue = nextAutoSyncHint(p);

  return el("section", { class: "panel" },
    el("h2", {}, "Auto-sync schedule"),
    el("p", { class: "sub" },
      "How often the scheduler ticks this profile. Runs always go through the shared queue, ",
      "so only one bank syncs at a time. Manual ", el("strong", {}, "Sync now"), " presses still work either way.",
    ),
    el("div", { class: "row schedule-row" },
      el("label", { class: "schedule-label" }, "Interval"),
      select,
      customInput,
      saveBtn,
    ),
    nextDue ? el("p", { class: "sub schedule-next" }, nextDue) : null,
    status,
  );
}

function nextAutoSyncHint(p) {
  if (!p.sync_interval_seconds) return null;
  if (!p.last_synced_at) return "Auto-sync runs on the next tick after the first manual sync.";
  const last = Date.parse(p.last_synced_at);
  if (Number.isNaN(last)) return null;
  const due = last + p.sync_interval_seconds * 1000;
  const diffSec = Math.round((due - Date.now()) / 1000);
  if (diffSec <= 0) return "Auto-sync is due — the next ticker pass will enqueue it.";
  return `Next auto-sync in ~${formatInterval(diffSec)} (after the last successful sync).`;
}

function renderActionsPanel(p) {
  const primary = p.state === "needs_reauth" ? "Re-authenticate (VNC)" : "Sync now";
  return el("section", { class: "panel" },
    el("h2", {}, "Actions"),
    el("div", { class: "detail-actions" },
      btn(primary, () => actions.onSync && actions.onSync(p, p.state === "needs_reauth"),
        p.state === "needs_reauth" ? "primary" : ""),
      btn("Browse",       () => actions.onBrowse && actions.onBrowse(p.profile_key)),
      btn("Record",       () => actions.onRecord && actions.onRecord(p.profile_key)),
      btn("Setup token",  () => actions.onMintToken && actions.onMintToken(p.profile_key)),
      btn("Credentials",  () => actions.onOpenCredentials && actions.onOpenCredentials(p)),
    ),
    el("p", { class: "sub", style: "margin-top: var(--space-3)" },
      "Credentials and setup-token forms still surface in the ",
      el("a", { href: "#/manage" }, "Manage view"),
      " — they'll move here in a later pass.",
    ),
  );
}

function btn(label, onclick, extraClass = "") {
  return el("button", { type: "button", class: extraClass, onclick }, label);
}

function renderDangerZone(p) {
  return el("section", { class: "panel danger-zone" },
    el("h3", {}, "Danger zone"),
    el("p", { class: "sub" },
      "These actions touch state in ways that downstream clients (Actual, etc.) will notice."),
    el("div", { class: "row" },
      btn("Rotate access URL",  () => actions.onRotateUrl    && actions.onRotateUrl(p.profile_key)),
      btn("Clear session",      () => actions.onClearSession && actions.onClearSession(p.profile_key)),
      btn("Rebuild history",    () => actions.onRebuildHistory && actions.onRebuildHistory(p)),
      btn("Reset history",      () => actions.onResetHistory   && actions.onResetHistory(p)),
      btn("Delete profile",     () => actions.onDelete         && actions.onDelete(p.profile_key)),
    ),
  );
}
