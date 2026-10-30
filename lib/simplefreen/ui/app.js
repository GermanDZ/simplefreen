import { api } from "./lib/api.js";
import { setState } from "./lib/store.js";
import { register as registerRoute, start as startRouter, navigate } from "./lib/router.js";
import * as toast from "./lib/toast.js";
import { confirm as confirmModal } from "./lib/modal.js";
import * as theme from "./lib/theme.js";
import * as dashboardView from "./views/dashboard.js";
import * as welcomeView from "./views/welcome.js";
import * as profileDetailView from "./views/profile_detail.js";
import * as consolidationOverviewView from "./views/consolidation_overview.js";
import {
  el,
  truncateMiddle,
  copyOnClick,
  flashCopied,
  copyToClipboard,
  fallbackCopy,
} from "./lib/dom.js";
import {
  formatInterval,
  formatBytes,
  formatDuration,
  lookbackLabel,
  historyLabel,
  formatWindow,
  confTier,
  isoPrevDay,
  quoteIfNeeded,
  urlPathHint,
} from "./lib/format.js";

(() => {
  const $ = (sel) => document.querySelector(sel);
  const profilesEl = $("#profiles");
  const newPanel = $("#new-profile-panel");
  const credPanel = $("#credentials-panel");
  const tokenPanel = $("#setup-token-panel");
  const tokenValue = $("#setup-token-value");

  let workflowsCache = null;
  let workflowsMeta = null;   // last refresh: { ref, commit, providers, repo, fetched_at }

  // Convention: workflow paths look like `<provider_slug>/workflow.yml`.
  // The slug is what we show in the UI; the full path is what we
  // submit to the API and store on disk.
  const workflowLabel = (path) =>
    typeof path === "string" ? path.replace(/\/workflow\.yml$/, "") : path;

  // In-place render. Existing rows are patched; only changed cells are
  // touched. Runs panels (which hold expanded logs and scroll state) are
  // never recreated as long as the profile still exists.
  //
  // Virtual profiles (kind: "virtual" — the singleton "consolidated"
  // profile that anchors the merged SimpleFIN URL) are filtered out
  // here. They have no workflow/credentials/sync and live on the
  // Consolidation page, not the Manage list.
  function renderProfiles(allProfiles) {
    const profiles = (allProfiles || []).filter((p) => p.kind !== "virtual");
    if (!profiles.length) {
      profilesEl.replaceChildren(
        el("div", { class: "empty-state" },
          el("p", { class: "empty-title" }, "No profiles yet"),
          el("p", { class: "empty-sub" },
            "Click ", el("strong", {}, "+ New profile"),
            " above to set up your first bank source. You'll pick a workflow, ",
            "store credentials, and run an initial sync."),
        )
      );
      return;
    }
    // If we previously rendered the empty-state, clear it.
    const empty = profilesEl.querySelector(".empty-state, p.profile-meta");
    if (empty && profiles.length) empty.remove();

    const seenKeys = new Set();
    for (const p of profiles) {
      seenKeys.add(p.profile_key);
      let row = profilesEl.querySelector(`.profile-row[data-profile="${CSS.escape(p.profile_key)}"]`);
      if (!row) {
        row = el("div", { class: "profile-row", "data-profile": p.profile_key });
        profilesEl.appendChild(row);
      }
      renderProfileRow(row, p);
    }

    // Remove rows whose profile no longer exists (e.g. after delete).
    profilesEl.querySelectorAll(".profile-row").forEach((r) => {
      const k = r.getAttribute("data-profile");
      if (!seenKeys.has(k)) r.remove();
    });
  }

  function renderProfileRow(row, p) {
    const isReauth   = p.state === "needs_reauth";
    const primaryLbl = isReauth ? "Re-authenticate" : "Sync now";
    const meta = [
      workflowLabel(p.workflow),
      historyLabel(p),
      p.last_synced_at ? `last synced ${timeAgoForMeta(p.last_synced_at)}` : "never synced",
      p.sync_interval_seconds ? `auto-sync every ${formatInterval(p.sync_interval_seconds)}` : "manual sync",
      p.access_url_configured ? "access URL ✓" : "access URL pending",
      p.credential_names.length ? `${p.credential_names.length} secret${p.credential_names.length > 1 ? "s" : ""}` : "no secrets",
    ];

    const head = el("div", { class: "profile-row-head" },
      el("h3", { class: "profile-row-title" }, p.display_name || p.profile_key),
      el("span", { class: `state-pill state-${p.state}` }, p.state.replaceAll("_", " ")),
      el("span", { class: "profile-row-key" }, p.profile_key),
      el("a", {
        class: "profile-row-open",
        href: `#/profiles/${encodeURIComponent(p.profile_key)}`,
        title: "Open focused detail view (full actions + danger zone live here)",
      }, "Open detail →"),
    );

    const metaRow = el("p", { class: "profile-row-meta" }, meta.join(" · "));

    const lastRunRow = renderLastRunLine(p);

    const errorRow = p.last_error
      ? el("p", { class: "profile-row-error" },
          el("strong", {}, "Last error: "), p.last_error)
      : null;

    // Primary actions: the sync trigger plus the two flows that are
    // commonly chained off it (Setup token after first successful sync,
    // Credentials when secrets are missing or rotating). Browse is a
    // common warm-up step for sticky banks. Record + history mgmt +
    // danger zone now live exclusively in the detail page.
    const actions = el("div", { class: "profile-row-actions" },
      el("button", {
        class: isReauth ? "primary" : "primary",
        onclick: () => triggerSync(p, isReauth),
        title: isReauth
          ? "Re-authenticate via the inline VNC viewer in the active-job banner"
          : "Start a sync — Chrome runs windowed; watch live via the VNC viewer"
      }, primaryLbl),
      el("button", { onclick: () => mintSetupToken(p.profile_key) }, "Setup token"),
      el("button", { onclick: () => openCredentials(p) }, "Credentials"),
      el("button", {
        onclick: () => triggerBrowse(p.profile_key),
        title: "Open Chrome at the bank's URL via VNC; interact manually, then click Stop browsing"
      }, "Browse"),
    );

    const children = [head, metaRow];
    if (lastRunRow) children.push(lastRunRow);
    if (errorRow) children.push(errorRow);
    children.push(actions);

    // Only replace content if it actually differs — prevents the 2-second
    // poll from nuking in-flight interactions (hover, focus, selection).
    const rendered = children.map((c) => c.outerHTML).join("");
    if (row.dataset.rendered === rendered) return;
    row.dataset.rendered = rendered;
    row.replaceChildren(...children);
  }

  // Compact relative-time for profile-row meta. Imported timeAgo
  // returns "Mar 5, 2025" past a week; for the list we'd rather keep
  // it numeric (e.g. "9d ago") so all rows align visually.
  function timeAgoForMeta(input) {
    if (!input) return "never";
    const ts = typeof input === "number" ? input : Date.parse(input);
    if (Number.isNaN(ts)) return "never";
    const diffSec = Math.floor((Date.now() - ts) / 1000);
    if (diffSec < 60) return "just now";
    if (diffSec < 3600) return `${Math.floor(diffSec / 60)}m ago`;
    if (diffSec < 86400) return `${Math.floor(diffSec / 3600)}h ago`;
    return `${Math.floor(diffSec / 86400)}d ago`;
  }

  // "Last run" line under the meta row. Surfaces the *most recent*
  // run regardless of outcome — unlike `last_synced_at`, which only
  // updates on success. Falls back to nothing when the profile has
  // never run.
  function renderLastRunLine(p) {
    const r = p.last_run;
    if (!r) return null;
    const outcome = r.outcome || (r.exit_code === 0 ? "ready" : "error");
    const when = r.finished_at || r.started_at;
    const duration = (r.duration_ms != null) ? formatDuration(r.duration_ms) : null;
    const runIdShort = (r.run_id || "").slice(0, 12);

    const parts = [
      el("span", { class: `state-pill state-${outcome}` }, outcome.replaceAll("_", " ")),
      el("span", {}, `last run ${timeAgoForMeta(when)}`),
    ];
    if (duration)       parts.push(el("span", {}, `took ${duration}`));
    if (r.trigger)      parts.push(el("span", {}, `via ${r.trigger}`));
    if (runIdShort)     parts.push(el("code", { class: "profile-row-runid", title: r.run_id || "" }, runIdShort));

    return el("div", { class: "profile-row-last-run" }, ...parts.flatMap((p, i) =>
      i === 0 ? [p] : [document.createTextNode(" · "), p]
    ));
  }

  async function toggleRuns(key) {
    const panel = document.querySelector(`[data-runs-for="${CSS.escape(key)}"]`);
    if (!panel) return;
    if (!panel.classList.contains("hidden")) {
      panel.classList.add("hidden");
      return;
    }
    await loadRunsInto(panel, key);
    panel.classList.remove("hidden");
  }

  // Populate a runs-panel container with the full per-run UI
  // (status, accounts/txns counts, canonical viewer, log toggle,
  // artifact gallery, recording transcript). Used by the profile
  // detail page via the onLoadRuns handler.
  async function loadRunsInto(panel, key) {
    if (!panel) return;
    panel.innerHTML = "Loading runs…";
    try {
      const data = await api(`/admin/api/profiles/${encodeURIComponent(key)}/runs`);
      panel.innerHTML = "";
      if (!data || !data.runs || !data.runs.length) {
        panel.appendChild(el("div", { class: "empty-state" },
          el("p", { class: "empty-title" }, "No runs yet"),
          el("p", { class: "empty-sub" }, "Trigger a sync to capture the first run."),
        ));
        return;
      }
      for (const run of data.runs) {
        panel.appendChild(renderRun(key, run));
      }
    } catch (e) {
      panel.innerHTML = "";
      panel.appendChild(el("p", { class: "profile-row-error" },
        el("strong", {}, "Failed to load runs: "), e.message));
    }
  }

  function renderRun(key, run) {
    const status = run.outcome || (run.exit_code === 0 ? "ready" : "error");
    const artifacts = Array.isArray(run.artifacts) ? run.artifacts : [];
    const screenshots = artifacts.filter((a) => a.kind === "screenshot");
    const others      = artifacts.filter((a) => a.kind !== "screenshot");

    const row = el("div", { class: "run-row" },
      el("div", { class: "run-row-head" },
        el("span", { class: `state-pill state-${status}` }, status.replaceAll("_", " ")),
        el("span", {}, run.run_id),
        el("span", { class: "profile-meta" }, run.started_at ? new Date(run.started_at).toLocaleString() : ""),
        run.duration_ms != null ? el("span", { class: "profile-meta" }, `${run.duration_ms}ms`) : null,
        artifacts.length ? el("span", { class: "profile-meta" }, `${artifacts.length} artifact${artifacts.length > 1 ? "s" : ""}`) : null,
        run.has_recording ? el("span", { class: "profile-meta" }, "recording ✓") : null,
        el("button", { onclick: (e) => toggleRunLog(key, run.run_id, e.target.closest(".run-row")) }, "Log"),
        run.has_recording
          ? el("button", { onclick: () => showRunRecording(key, run.run_id) }, "Recording")
          : null
      ),
      run.message ? el("div", { class: "profile-meta" }, run.message) : null,
      el("pre", { class: "run-log hidden" }, ""),
      // Screenshot gallery — visible by default for failed runs (the
      // moment-of-failure screenshot is the most useful debug artifact),
      // collapsible for successful runs.
      screenshots.length
        ? el("details", { class: "artifact-gallery", open: status === "error" ? "" : null },
            el("summary", { class: "artifact-summary" },
              `${screenshots.length} screenshot${screenshots.length > 1 ? "s" : ""}`
            ),
            el("div", { class: "artifact-grid" },
              ...screenshots.map((shot) => artifactThumbnail(key, run.run_id, shot))
            )
          )
        : null,
      // Other artifacts (logs, exports, reports) as a flat link list.
      others.length
        ? el("details", { class: "artifact-files" },
            el("summary", { class: "artifact-summary" },
              `${others.length} other file${others.length > 1 ? "s" : ""}`
            ),
            el("ul", { class: "artifact-list" },
              ...others.map((a) => el("li", {},
                el("span", { class: "artifact-kind" }, `[${a.kind}]`),
                el("a", {
                  href: `/admin/api/profiles/${encodeURIComponent(key)}/runs/${encodeURIComponent(run.run_id)}/artifacts/${a.index}`,
                  target: "_blank",
                  rel: "noreferrer"
                }, a.name)
              ))
            )
          )
        : null,
      // Canonical data — what freentonic actually pushed for this run.
      // Renders as accounts + transactions tables, with a raw-JSON toggle.
      // Loaded lazily on first expand.
      run.canonical ? renderCanonicalSection(key, run) : null
    );
    return row;
  }

  function renderCanonicalSection(key, run) {
    const meta = run.canonical || {};
    const acc = meta.accounts_count || 0;
    const txs = meta.transactions_count || 0;
    const errs = meta.reshape_errors || 0;
    const summary = `${acc} account${acc === 1 ? "" : "s"} · ${txs} transaction${txs === 1 ? "" : "s"}` +
      (errs ? ` · ${errs} reshape error${errs === 1 ? "" : "s"}` : "");

    const body = el("div", { class: "canonical-body" }, "Loading…");
    const details = el("details", { class: "canonical-section" },
      el("summary", { class: "artifact-summary" }, "Data: ", summary),
      body
    );
    details.addEventListener("toggle", () => {
      if (!details.open || details.dataset.loaded === "1") return;
      details.dataset.loaded = "1";
      loadCanonical(key, run.run_id, body);
    });
    return details;
  }

  async function loadCanonical(key, runId, body) {
    try {
      const data = await api(
        `/admin/api/profiles/${encodeURIComponent(key)}/runs/${encodeURIComponent(runId)}/canonical`
      );
      renderCanonicalBody(body, data);
    } catch (e) {
      body.textContent = `Failed to load data: ${e.message}`;
    }
  }

  function renderCanonicalBody(body, payload) {
    body.replaceChildren();

    const tablesView = renderCanonicalTables(payload);
    const rawView = el("pre", { class: "canonical-raw hidden" }, JSON.stringify(payload, null, 2));

    const tablesBtn = el("button", { class: "canonical-tab active", type: "button" }, "Tables");
    const rawBtn    = el("button", { class: "canonical-tab", type: "button" }, "Raw JSON");
    tablesBtn.addEventListener("click", () => {
      tablesView.classList.remove("hidden");
      rawView.classList.add("hidden");
      tablesBtn.classList.add("active");
      rawBtn.classList.remove("active");
    });
    rawBtn.addEventListener("click", () => {
      tablesView.classList.add("hidden");
      rawView.classList.remove("hidden");
      rawBtn.classList.add("active");
      tablesBtn.classList.remove("active");
    });

    body.appendChild(el("div", { class: "canonical-tabs" }, tablesBtn, rawBtn));
    body.appendChild(tablesView);
    body.appendChild(rawView);
  }

  function renderCanonicalTables(payload) {
    const accounts = Array.isArray(payload.accounts) ? payload.accounts : [];
    const transactions = Array.isArray(payload.transactions) ? payload.transactions : [];
    const accountNames = {};
    for (const a of accounts) accountNames[a && a.id] = a && (a.name || a.id);

    const wrap = el("div", { class: "canonical-tables" });

    wrap.appendChild(el("h4", { class: "canonical-heading" }, `Accounts (${accounts.length})`));
    if (accounts.length) {
      wrap.appendChild(renderAccountsTable(accounts));
    } else {
      wrap.appendChild(el("p", { class: "profile-meta" }, "No accounts."));
    }

    wrap.appendChild(el("h4", { class: "canonical-heading" }, `Transactions (${transactions.length})`));
    if (transactions.length) {
      wrap.appendChild(renderTransactionsTable(transactions, accountNames));
    } else {
      wrap.appendChild(el("p", { class: "profile-meta" }, "No transactions."));
    }
    return wrap;
  }

  function renderAccountsTable(accounts) {
    const head = el("tr", {},
      el("th", {}, "Name"),
      el("th", { class: "canonical-id-col" }, "acc_<hex>"),
      el("th", {}, "source_id"),
      el("th", {}, "IBAN"),
      el("th", {}, "Institution"),
      el("th", {}, "Currency"),
      el("th", { class: "num" }, "Current"),
      el("th", { class: "num" }, "Available"),
      el("th", {}, "As of")
    );
    const rows = accounts.map((a) => {
      const bal = (a && a.balance) || {};
      return el("tr", {},
        el("td", {}, (a && (a.name || a.id)) || ""),
        el("td", { class: "canonical-id-cell", title: (a && a.id) || "" },
          el("code", { onclick: copyOnClick }, (a && a.id) || "")),
        el("td", { class: "canonical-id-cell", title: (a && a.source_id) || "" },
          el("code", { onclick: copyOnClick }, truncateMiddle((a && a.source_id) || "", 28))),
        el("td", { class: "canonical-id-cell" }, (a && a.iban) || ""),
        el("td", {}, (a && a.institution) || ""),
        el("td", {}, (a && a.currency) || ""),
        el("td", { class: "num" }, bal.current != null ? String(bal.current) : ""),
        el("td", { class: "num" }, bal.available != null ? String(bal.available) : ""),
        el("td", {}, bal.timestamp ? new Date(bal.timestamp).toLocaleString() : "")
      );
    });
    return el("table", { class: "canonical-table" },
      el("thead", {}, head),
      el("tbody", {}, ...rows)
    );
  }

  // Truncate a long opaque string in the middle so the start (which
  // usually carries the meaningful prefix like a bank code) and end
  // (which carries the discriminating tail) both stay visible. Used
  // for source_ids, which can run to 64+ chars for opaque resourceId
  // hashes.
  const TX_DEFAULT_LIMIT = 200;

  function renderTransactionsTable(transactions, accountNames) {
    const wrap = el("div", {});
    const tbody = el("tbody", {});
    const head = el("tr", {},
      el("th", {}, "Date"),
      el("th", { class: "num" }, "Amount"),
      el("th", {}, "Cur"),
      el("th", {}, "Description"),
      el("th", {}, "Merchant"),
      el("th", {}, "Account"),
      el("th", { class: "canonical-id-col" }, "txn_<hex>"),
      el("th", {}, "source_id"),
      el("th", {}, "Status")
    );

    const fill = (limit) => {
      tbody.replaceChildren();
      const slice = transactions.slice(0, limit);
      for (const t of slice) {
        const merchant = (t && t.merchant && t.merchant.name) || "";
        tbody.appendChild(el("tr", {},
          el("td", {}, (t && t.date) || ""),
          el("td", { class: "num" }, t && t.amount != null ? String(t.amount) : ""),
          el("td", {}, (t && t.currency) || ""),
          el("td", {}, (t && (t.description || t.raw_description)) || ""),
          el("td", {}, merchant),
          el("td", {}, accountNames[t && t.account_id] || (t && t.account_id) || ""),
          el("td", { class: "canonical-id-cell", title: (t && t.id) || "" },
            el("code", { onclick: copyOnClick }, (t && t.id) || "")),
          el("td", { class: "canonical-id-cell", title: (t && t.source_id) || "" },
            el("code", { onclick: copyOnClick }, truncateMiddle((t && t.source_id) || "", 24))),
          el("td", {}, (t && t.status) || "")
        ));
      }
    };

    fill(TX_DEFAULT_LIMIT);
    wrap.appendChild(el("table", { class: "canonical-table" },
      el("thead", {}, head),
      tbody
    ));

    if (transactions.length > TX_DEFAULT_LIMIT) {
      const showAll = el("button", { class: "canonical-show-all", type: "button" },
        `Show all ${transactions.length} transactions`
      );
      showAll.addEventListener("click", () => {
        fill(transactions.length);
        showAll.remove();
      });
      wrap.appendChild(showAll);
    }
    return wrap;
  }

  function artifactThumbnail(key, runId, shot) {
    const url = `/admin/api/profiles/${encodeURIComponent(key)}/runs/${encodeURIComponent(runId)}/artifacts/${shot.index}`;
    return el("a", { href: url, target: "_blank", rel: "noreferrer", class: "artifact-thumb", title: shot.name },
      el("img", { src: url, loading: "lazy", alt: shot.name }),
      el("span", { class: "artifact-thumb-caption" }, shot.name)
    );
  }

  async function toggleRunLog(key, runId, rowEl) {
    const pre = rowEl.querySelector(".run-log");
    if (!pre.classList.contains("hidden")) {
      pre.classList.add("hidden");
      return;
    }
    pre.textContent = "Loading…";
    pre.classList.remove("hidden");
    try {
      const data = await api(`/admin/api/profiles/${encodeURIComponent(key)}/runs/${encodeURIComponent(runId)}/log`);
      pre.textContent = data.log || "(empty log)";
      if (data.truncated) {
        pre.textContent = "…(earlier output truncated)\n" + pre.textContent;
      }
    } catch (e) {
      pre.textContent = `Failed to load log: ${e.message}`;
    }
  }

  let liveLogTimer = null;
  let liveLogRunId = null;
  let liveLogProfile = null;
  // Incremental-tail state: after the first poll seeds the current tail, we
  // only fetch bytes past `liveLogOffset` and append them to `liveLogBuffer`,
  // instead of re-pulling the whole log every 2 s.
  let liveLogOffset = 0;
  let liveLogBuffer = "";
  let liveLogPrimed = false;
  let liveLogTruncated = false;

  async function refresh() {
    try {
      const [status, healthz] = await Promise.all([
        api("/admin/api/status"),
        fetch("/healthz", { credentials: "same-origin" })
          .then((r) => (r.ok ? r.json() : null))
          .catch(() => null)
      ]);
      if (!status) return;
      setState("profiles", status.profiles);
      setState("activeJob", status.active_job);
      setState("queuePending", status.pending || []);
      setState("freentonicHealth", healthz && healthz.freentonic);
      renderProfiles(status.profiles);
      renderActiveJob(status.active_job, status.pending || []);
      renderFreentonicHealth(healthz && healthz.freentonic);
    } catch (e) {
      console.error(e);
    }
  }

  // ── consolidation (linked accounts across profiles) ──────
  //
  // Pulled on a slower cadence than the 2-second status refresh — it
  // requires reading every profile's latest canonical, which is
  // cheap-but-not-free, and the data only changes when a sync completes
  // or the operator edits aliases. Refreshed eagerly after edits.

  let consolidationCache = null;

  async function loadConsolidation() {
    try {
      const data = await api("/admin/api/consolidation/groups");
      if (!data) return;
      consolidationCache = data;
      setState("consolidation", data);
      renderConsolidation(data);
    } catch (e) {
      console.error("loadConsolidation failed:", e);
    }
  }

  function renderConsolidation(data) {
    const wrap = document.getElementById("consolidation-groups");
    const meta = document.getElementById("consolidation-meta");
    if (!wrap) return;

    const groups       = (data && data.groups) || [];
    const suggestions  = (data && data.suggestions) || [];
    const linkedCount  = groups.filter((g) => g.sources.length > 1).length;
    const aliasCount   = (data && data.alias_count) || 0;
    const profCount    = (data && data.profile_count) || 0;
    if (meta) {
      const sugTxt = suggestions.length ? ` · ${suggestions.length} suggestion${suggestions.length === 1 ? "" : "s"}` : "";
      meta.textContent = `${linkedCount} linked across ${profCount} source${profCount === 1 ? "" : "s"} · ${aliasCount} alias${aliasCount === 1 ? "" : "es"}${sugTxt}`;
    }

    wrap.innerHTML = "";

    // Suggestions first — these are calls to action: confirm or dismiss.
    if (suggestions.length) {
      const suggSection = el("div", { class: "consolidation-suggestions" });
      suggSection.appendChild(el("h3", { class: "consolidation-section-h" },
        `Suggested matches (${suggestions.length})`));
      suggSection.appendChild(el("p", { class: "sub" },
        "Account pairs whose recent transactions overlap. Review the samples and click Link if they're the same physical account."));
      suggestions.forEach((s) => suggSection.appendChild(renderSuggestionRow(s)));
      wrap.appendChild(suggSection);
    }

    if (!groups.length) {
      wrap.appendChild(el("div", { class: "empty-state" },
        el("p", { class: "empty-title" }, "No accounts to link yet"),
        el("p", { class: "empty-sub" },
          "Sync at least one profile so the canonicals are on disk — ",
          "once accounts appear across two or more sources, they'll show up here for linking."),
      ));
      return;
    }

    // Show multi-source groups first, then a collapsible bucket of
    // singletons so the panel doesn't drown in 12 Revolut pockets.
    const linked = groups.filter((g) => g.sources.length > 1 || g.linked_via === "dangling");
    const singletons = groups.filter((g) => g.sources.length === 1);

    if (linked.length) {
      const linkedHead = el("h3", { class: "consolidation-section-h" }, `Linked groups (${linked.length})`);
      wrap.appendChild(linkedHead);
      linked.forEach((g) => wrap.appendChild(renderGroupRow(g, { collapsed: false })));
    } else if (!suggestions.length) {
      wrap.appendChild(el("p", { class: "sub" }, "No cross-source links yet. Once two providers see the same physical account (auto-linked) or you add a manual alias, they'll appear here."));
    }

    if (singletons.length) {
      const details = el("details", { class: "consolidation-singletons" });
      details.appendChild(el("summary", {}, `Single-source accounts (${singletons.length})`));
      singletons.forEach((g) => details.appendChild(renderGroupRow(g, { collapsed: true })));
      wrap.appendChild(details);
    }
  }

  function renderSuggestionRow(s) {
    const row = el("div", { class: "consolidation-suggestion" });

    const head = el("div", { class: "consolidation-group-head" });
    const pct  = `${(s.confidence * 100).toFixed(0)}%`;
    const conf = el("span", { class: `consolidation-badge consolidation-conf-${confTier(s.confidence)}` }, `${pct} match`);
    head.appendChild(conf);
    head.appendChild(el("span", { class: "consolidation-suggestion-summary" },
      `${s.profile_a} / ${s.account_a.name || s.account_a.id}  ↔  ${s.profile_b} / ${s.account_b.name || s.account_b.id}`));

    const overlapTxt = el("span", { class: "consolidation-overlap" },
      `${s.overlap} overlap of ${Math.min(s.a_total, s.b_total)} (a:${s.a_total} / b:${s.b_total})`);
    head.appendChild(overlapTxt);

    const linkBtn = el("button", {
      type: "button",
      class: "consolidation-suggestion-link",
      onclick: () => linkSuggestion(s)
    }, "Link");
    head.appendChild(linkBtn);

    row.appendChild(head);

    if (s.samples && s.samples.length) {
      const samples = el("div", { class: "consolidation-samples" });
      samples.appendChild(el("span", { class: "sub" }, "Sample shared txns: "));
      s.samples.forEach((x, i) => {
        if (i > 0) samples.appendChild(document.createTextNode(" · "));
        samples.appendChild(el("code", { class: "consolidation-sample-tx" },
          `${x.date} ${x.amount} ${x.currency || ""}`.trim()));
      });
      row.appendChild(samples);
    }

    return row;
  }

  async function linkSuggestion(s) {
    const a = s.account_a.id;
    const b = s.account_b.id;
    const note = `auto-suggested: ${s.profile_a}/${s.account_a.name || a} ↔ ${s.profile_b}/${s.account_b.name || b} (${s.overlap}/${Math.min(s.a_total, s.b_total)} overlap)`;
    const ok = await confirmModal({
      title: "Link these accounts as the same physical account?",
      body:  el("div", {},
        el("pre", { style: "margin:0 0 8px; font-size: var(--fs-sm); white-space: pre-wrap" },
          `${a}\n${b}`),
        el("p", { style: "margin:0; font-size: var(--fs-sm); color: var(--fg-muted)" }, note),
      ),
      confirmLabel: "Link accounts",
    });
    if (!ok) return;
    const existing = await api("/admin/api/consolidation/aliases");
    const aliases = ((existing && existing.aliases) || []).slice();
    aliases.push({ members: [a, b], note });
    try {
      await api("/admin/api/consolidation/aliases", { method: "PUT", body: { aliases } });
      await loadConsolidation();
      toast.success("Accounts linked.");
    } catch (e) {
      toast.error(`Link failed: ${e.message}`);
    }
  }

  function renderGroupRow(group, { collapsed }) {
    const badge = el("span", { class: `consolidation-badge consolidation-badge-${group.linked_via}` },
      group.linked_via === "portable_ref" ? "auto" :
      group.linked_via === "alias"        ? "alias" :
      group.linked_via === "dangling"     ? "stale" : "single"
    );

    // Single-source groups render flat (no expand surface — there's
    // nothing under the head worth a click). Multi-source linked
    // groups render as <details> so the sources table is hidden
    // until the operator drills in.
    if (collapsed) {
      const row = el("div", { class: `consolidation-group consolidation-${group.linked_via}` });
      const head = el("div", { class: "consolidation-group-head" }, badge,
        el("code", { class: "consolidation-id" }, group.id));
      row.appendChild(head);
      const s = group.sources[0];
      if (s) {
        row.appendChild(el("span", { class: "sub consolidation-singleton-sub" },
          `${s.profile_key} · ${s.name || s.account_id}`));
      }
      return row;
    }

    const summary = el("summary", { class: "consolidation-group-head" },
      badge,
      el("code", { class: "consolidation-id" }, group.id),
      el("span", { class: "consolidation-group-srcs" },
        `${group.sources.length} source${group.sources.length === 1 ? "" : "s"}`),
      group.suggested_primary
        ? el("span", { class: "consolidation-primary" }, `primary: ${group.suggested_primary.profile_key}`)
        : null,
      group.linked_via === "alias"
        ? el("button", {
            type: "button",
            class: "consolidation-remove-alias",
            title: "Remove the manual alias linking these accounts (auto-links via portable_ref will not be affected)",
            onclick: (ev) => { ev.preventDefault(); ev.stopPropagation(); removeAlias(group.members); },
          }, "Unlink")
        : null,
    );

    const list = el("table", { class: "consolidation-sources" });
    const header = el("tr", {});
    ["Source", "Account", "Institution", "IBAN", "Txns", "Balance"].forEach((h) =>
      header.appendChild(el("th", {}, h))
    );
    list.appendChild(header);
    group.sources.forEach((s) => {
      const tr = el("tr", {});
      tr.appendChild(el("td", { class: "consolidation-src-key" }, s.profile_key));
      tr.appendChild(el("td", {}, s.name || s.account_id));
      tr.appendChild(el("td", { class: "consolidation-src-inst" }, s.institution || "—"));
      tr.appendChild(el("td", { class: "consolidation-src-iban" }, s.iban || "—"));
      tr.appendChild(el("td", { class: "consolidation-src-txns" }, String(s.txn_count)));
      tr.appendChild(el("td", { class: "consolidation-src-bal" }, s.balance != null ? `${s.balance} ${s.currency || ""}`.trim() : "—"));
      list.appendChild(tr);
    });

    return el("details", { class: `consolidation-group consolidation-${group.linked_via}` },
      summary, list);
  }

  async function addAlias() {
    const a = window.prompt(
      "First account ID (acc_<16 hex>):\n\n" +
      "Tip: open the Linked-accounts panel above, find the two accounts you want to link, " +
      "and copy their acc_… ids."
    );
    if (!a) return;
    const b = window.prompt("Second account ID (acc_<16 hex>):");
    if (!b) return;
    const note = window.prompt("Note (optional, e.g. \"Unicaja Principal ↔ Fintonic 2103:hash\")", "") || "";

    const existing = await api("/admin/api/consolidation/aliases");
    const aliases = ((existing && existing.aliases) || []).slice();
    aliases.push({ members: [a.trim(), b.trim()], note: note.trim() });
    try {
      await api("/admin/api/consolidation/aliases", { method: "PUT", body: { aliases } });
      await loadConsolidation();
    } catch (e) {
      toast.error(`Alias add failed: ${e.message}`);
    }
  }

  async function removeAlias(members) {
    const ok = await confirmModal({
      title: "Remove this alias?",
      body:  el("div", {},
        el("p", { style: "margin:0 0 8px" }, "Accounts will no longer be linked as one physical account:"),
        el("pre", { style: "margin:0; font-size: var(--fs-sm); white-space: pre-wrap" }, members.join("\n")),
      ),
      confirmLabel: "Remove alias",
      danger: true,
    });
    if (!ok) return;
    const existing = await api("/admin/api/consolidation/aliases");
    const all = ((existing && existing.aliases) || []);
    // Drop any alias whose member set matches (order-independent).
    const target = members.slice().sort().join(",");
    const filtered = all.filter((a) => {
      const sig = (a.members || []).slice().sort().join(",");
      return sig !== target;
    });
    try {
      await api("/admin/api/consolidation/aliases", { method: "PUT", body: { aliases: filtered } });
      await loadConsolidation();
      toast.success("Alias removed.");
    } catch (e) {
      toast.error(`Alias remove failed: ${e.message}`);
    }
  }

  const addAliasBtn = document.getElementById("add-alias-btn");
  if (addAliasBtn) addAliasBtn.addEventListener("click", addAlias);

  // ── export preview ──────────────────────────────────────
  //
  // Surfaces the actual contents of the consolidated SimpleFIN feed
  // operators are pointing Sure.am / Actual at. Three sections:
  //   - Accounts that will be emitted (with per-source contribution).
  //   - Hidden suppressions (source-level hidden_accounts being honoured).
  //   - Lookalike singleton pairs the operator should consider aliasing.
  // Also renders any operator-facing warnings (overlap/gap/coverage)
  // produced by the merge so the full export picture is in one view.

  async function loadExportPreview() {
    try {
      const data = await api("/admin/api/consolidation/export-preview");
      if (!data) return;
      setState("exportPreview", data);
      renderExportPreview(data);
    } catch (e) {
      console.error("loadExportPreview failed:", e);
    }
  }

  function renderExportPreview(data) {
    const wrap = document.getElementById("export-preview-body");
    const meta = document.getElementById("export-preview-meta");
    if (!wrap) return;

    const accounts     = (data && data.accounts) || [];
    const suppressions = (data && data.hidden_suppressions) || [];
    const lookalikes   = (data && data.lookalike_pairs) || [];
    const warnings     = (data && data.warnings) || [];

    if (meta) {
      const totalTxns = accounts.reduce((n, a) => n + (a.txn_count_total || 0), 0);
      meta.textContent = `${accounts.length} account${accounts.length === 1 ? "" : "s"} · ${totalTxns} transaction${totalTxns === 1 ? "" : "s"}`;
    }

    wrap.innerHTML = "";

    if (!accounts.length && !suppressions.length && !lookalikes.length) {
      wrap.appendChild(el("div", { class: "empty-state" },
        el("p", { class: "empty-title" }, "Nothing to export yet"),
        el("p", { class: "empty-sub" },
          "Sync at least one profile so the consolidated feed has data. ",
          "This panel mirrors exactly what the merged SimpleFIN URL is currently emitting."),
      ));
      return;
    }

    if (warnings.length) {
      const warnWrap = el("div", { class: "export-preview-warnings" });
      warnings.forEach((w) => warnWrap.appendChild(
        el("div", { class: `export-preview-warning warning-${w.kind}` },
          el("strong", {}, `${w.kind}: `), w.message)
      ));
      wrap.appendChild(warnWrap);
    }

    if (accounts.length) {
      const accSection = el("div", { class: "export-preview-section" });
      accSection.appendChild(el("h3", { class: "consolidation-section-h" },
        `Will be exported (${accounts.length})`));
      accounts.forEach((a) => accSection.appendChild(renderExportAccount(a)));
      wrap.appendChild(accSection);
    }

    if (suppressions.length) {
      const supSection = el("div", { class: "export-preview-section" });
      supSection.appendChild(el("h3", { class: "consolidation-section-h" },
        `Hidden — not exported (${suppressions.length})`));
      supSection.appendChild(el("p", { class: "sub" },
        "Accounts marked hidden on their source profile. Edit hidden_accounts on the profile to change."));
      suppressions.forEach((s) => supSection.appendChild(
        el("div", { class: "export-preview-suppression" },
          el("code", {}, s.profile_key),
          " · ",
          el("span", {}, s.name || s.account_id),
          el("span", { class: "sub" }, ` (${s.account_id})`))
      ));
      wrap.appendChild(supSection);
    }

    if (lookalikes.length) {
      const lookSection = el("div", { class: "export-preview-section" });
      lookSection.appendChild(el("h3", { class: "consolidation-section-h" },
        `Possibly the same account (${lookalikes.length})`));
      lookSection.appendChild(el("p", { class: "sub" },
        "Singleton accounts from different sources whose transaction streams overlap. Aliasing them collapses the duplicate into a single merged account."));
      lookalikes.forEach((p) => lookSection.appendChild(renderLookalikePair(p)));
      wrap.appendChild(lookSection);
    }
  }

  function renderExportAccount(a) {
    const sources = a.sources || [];
    const isMerged = a.member_count > 1 || sources.length > 1;

    const summary = el("summary", { class: "consolidation-group-head" },
      el("strong", { class: "export-account-name" }, a.name || a.id),
      el("span", { class: "export-account-txns" }, `${a.txn_count_total} txn`),
      el("span", { class: `consolidation-badge consolidation-badge-${isMerged ? "portable_ref" : "singleton"}` },
        isMerged ? `merged · ${sources.length} sources` : "singleton"),
      a.primary_source
        ? el("span", { class: "consolidation-primary" }, `primary: ${a.primary_source}`)
        : null,
    );

    // No sources table → no value in being a <details>; render flat.
    if (!sources.length) {
      return el("div", { class: "export-preview-account" }, summary);
    }

    const list = el("table", { class: "consolidation-sources" });
    sources.forEach((s) => {
      const tr = el("tr", {});
      tr.appendChild(el("td", { class: "consolidation-src-key" }, s.profile_key));
      const range = formatWindow(s.from, s.to);
      tr.appendChild(el("td", {}, range));
      tr.appendChild(el("td", { class: "consolidation-src-txns" },
        s.skipped ? "skipped" : `${s.txn_count} txn`));
      list.appendChild(tr);
    });

    return el("details", { class: "export-preview-account" }, summary, list);
  }

  function renderLookalikePair(p) {
    const row = el("div", { class: "consolidation-suggestion" });
    const head = el("div", { class: "consolidation-group-head" });
    const pct  = `${(p.confidence * 100).toFixed(0)}%`;
    head.appendChild(el("span", { class: `consolidation-badge consolidation-conf-${confTier(p.confidence)}` },
      `${pct} match`));
    head.appendChild(el("span", { class: "consolidation-suggestion-summary" },
      `${p.profile_a} / ${(p.account_a && p.account_a.name) || (p.account_a && p.account_a.id) || "?"} ↔ ${p.profile_b} / ${(p.account_b && p.account_b.name) || (p.account_b && p.account_b.id) || "?"}`));
    head.appendChild(el("span", { class: "consolidation-overlap" },
      `${p.overlap} of ${Math.min(p.a_total, p.b_total)} shared`));
    const linkBtn = el("button", {
      type: "button",
      class: "consolidation-suggestion-link",
      // linkSuggestion already accepts the serialized-suggestion shape and
      // calls loadConsolidation; we additionally refresh the export preview
      // so the operator sees the merged account take its place immediately.
      onclick: async () => {
        await linkSuggestion(p);
        await loadExportPreview();
      }
    }, "Create alias");
    head.appendChild(linkBtn);
    row.appendChild(head);
    return row;
  }
  // ── virtual consolidated profile + per-group window editor ──

  let virtualCache = null;

  async function loadVirtualProfile() {
    try {
      const data = await api("/admin/api/consolidation/groups-config");
      if (!data) return;
      virtualCache = data;
      setState("virtualProfile", data);
      renderVirtualProfile(data);
    } catch (e) {
      console.error("loadVirtualProfile failed:", e);
    }
  }

  function renderVirtualProfile(data) {
    const body  = document.getElementById("virtual-profile-body");
    const meta  = document.getElementById("virtual-profile-meta");
    const setupBtn = document.getElementById("virtual-profile-create-btn");
    const resetBtn = document.getElementById("virtual-profile-reset-primaries-btn");
    if (!body) return;

    const vp        = data && data.virtual_profile;
    const groups    = (data && data.groups) || [];
    const warnings  = (data && data.warnings) || [];
    const linked    = groups.filter((g) => g.sources.length > 1);

    if (!vp) {
      if (meta)     meta.textContent = "not set up";
      if (setupBtn) setupBtn.hidden = false;
      if (resetBtn) resetBtn.hidden = true;
      body.replaceChildren(el("div", { class: "empty-state" },
        el("p", { class: "empty-title" }, "Consolidated profile not set up"),
        el("p", { class: "empty-sub" },
          "Click ", el("strong", {}, "Set up consolidated profile"),
          " above to mint the singleton profile that aggregates every source ",
          "into one SimpleFIN URL. Per-source date windows can be configured after setup."),
      ));
      return;
    }

    if (meta) {
      meta.textContent = `${linked.length} multi-source group${linked.length === 1 ? "" : "s"} · ${warnings.length} warning${warnings.length === 1 ? "" : "s"}`;
    }
    if (setupBtn) setupBtn.hidden = true;

    // Show the reset-primaries sweep only when at least one linked
    // group has a pin that disagrees with the heuristic. Otherwise
    // the button would be a no-op surface.
    if (resetBtn) {
      const stale = collectStalePins(linked);
      resetBtn.hidden = stale.length === 0;
      if (stale.length) {
        resetBtn.textContent = `Reset ${stale.length} stale primar${stale.length === 1 ? "y" : "ies"}`;
      } else {
        resetBtn.textContent = "Reset primaries to suggested";
      }
    }

    body.innerHTML = "";
    body.appendChild(renderVirtualSummary(vp));
    body.appendChild(renderVirtualServeWindow(vp));

    if (warnings.length) {
      const warnEl = el("div", { class: "vp-warnings" });
      warnEl.appendChild(el("h4", { class: "vp-h" }, "Warnings"));
      warnings.forEach((w) => warnEl.appendChild(renderWarning(w)));
      body.appendChild(warnEl);
    }

    if (linked.length) {
      body.appendChild(el("h4", { class: "vp-h" }, "Per-group windows"));
      body.appendChild(el("p", { class: "sub" },
        "Each multi-source group can split its timeline by source. ",
        "Default is primary-only (primary covers all dates, secondaries serve nothing)."));
      linked.forEach((g) => body.appendChild(renderGroupConfigRow(g)));
    } else {
      body.appendChild(el("p", { class: "sub" },
        "No multi-source groups yet — once two providers link to the same physical account ",
        "(via portable_ref or alias), per-source windows will appear here."));
    }
  }

  function renderVirtualSummary(vp) {
    const wrap = el("div", { class: "vp-summary" });
    wrap.appendChild(el("span", { class: "vp-key" }, "consolidated"));
    if (vp.access_url_configured) {
      wrap.appendChild(el("span", { class: "vp-state vp-state-ready" }, "access URL active"));
    } else {
      wrap.appendChild(el("span", { class: "vp-state vp-state-pending" }, "no access URL yet"));
    }
    const tokenBtn = el("button", {
      type: "button", class: "vp-setup-token",
      onclick: () => mintVirtualSetupToken()
    }, vp.access_url_configured ? "Rotate setup token…" : "Mint setup token");
    wrap.appendChild(tokenBtn);
    return wrap;
  }

  // Server-side clamp on the consolidated SimpleFIN feed: even if Sure
  // (or any client) requests the full history on first sync, we'll only
  // serve transactions newer than (now - serve_max_days). Empty / 0
  // disables the clamp; canonical limit is 3650 days.
  function renderVirtualServeWindow(vp) {
    const wrap   = el("div", { class: "vp-serve-window" });
    const cur    = vp.serve_max_days;
    const input  = el("input", {
      type: "number", min: "0", max: "3650", step: "1",
      class: "vp-serve-window-input",
      placeholder: "no limit",
      value: cur != null ? String(cur) : ""
    });
    const status = el("span", { class: "sub" });
    const saveBtn = el("button", {
      type: "button",
      class: "vp-serve-window-save",
      onclick: async () => {
        const raw = input.value.trim();
        const parsed = raw === "" ? null : parseInt(raw, 10);
        if (raw !== "" && (!Number.isFinite(parsed) || parsed < 0 || parsed > 3650)) {
          status.textContent = "must be 0..3650 (empty = no limit)";
          return;
        }
        status.textContent = "saving…";
        try {
          await api(`/admin/api/profiles/consolidated`, {
            method: "PATCH", body: { serve_max_days: parsed }
          });
          status.textContent = parsed ? `clamped to last ${parsed} days` : "no clamp";
          await loadVirtualProfile();
        } catch (e) {
          status.textContent = `save failed: ${e.message}`;
        }
      }
    }, "Save");

    wrap.appendChild(el("label", { class: "vp-serve-window-label" }, "Serve last "));
    wrap.appendChild(input);
    wrap.appendChild(el("span", { class: "sub" }, " days (empty = no clamp; protects fresh-install clients from pulling years of history)"));
    wrap.appendChild(saveBtn);
    wrap.appendChild(status);
    return wrap;
  }

  function renderWarning(w) {
    return el("div", { class: `vp-warning vp-warning-${w.kind}` },
      el("span", { class: "vp-warning-kind" }, w.kind.replace(/_/g, " ")),
      el("span", { class: "vp-warning-msg" }, w.message)
    );
  }

  function renderGroupConfigRow(group) {
    const cfg = group.config || {};
    const win = cfg.windows || {};
    const earliest = group.earliest_dates || {};
    const sources = group.sources;
    const memberKey = group.members.slice().sort().join(",");

    // Whole editor card is now a <details> — closed by default so
    // the consolidated-profile panel reads as a scannable list of
    // groups instead of a wall of timelines + per-source date
    // inputs. Click any row to expand its editor.
    const row = el("details", { class: "vp-group" });
    const currentPrimary = cfg.primary || (group.suggested_primary && group.suggested_primary.profile_key);
    const hasWindows = Object.keys(win).length > 0;
    const summary = el("summary", { class: "vp-group-head" },
      el("code", { class: "vp-group-id" }, group.id),
      el("span", { class: "vp-group-srcs" }, `${sources.length} source${sources.length === 1 ? "" : "s"}`),
      currentPrimary
        ? el("span", { class: "vp-primary-label" }, "primary: ",
            el("code", {}, currentPrimary))
        : null,
      hasWindows
        ? el("span", { class: "vp-windows-marker", title: "Has per-source date windows configured" }, "windowed")
        : null,
      cfg.balance_override != null
        ? el("span", { class: "vp-balance-marker", title: `Balance override: ${cfg.balance_override}` }, `bal: ${cfg.balance_override}`)
        : null,
    );
    row.appendChild(summary);

    // Body section — controls only render when the details is open.
    // The select / inputs go here (not in <summary>) so clicking them
    // doesn't toggle the disclosure.
    const body = el("div", { class: "vp-group-body" });

    const controlsRow = el("div", { class: "vp-group-controls" });
    const primarySel = el("select", { class: "vp-primary-pick" });
    sources.forEach((s) => {
      const opt = el("option", { value: s.profile_key }, s.profile_key);
      if (s.profile_key === currentPrimary) opt.selected = true;
      primarySel.appendChild(opt);
    });
    controlsRow.appendChild(el("label", { class: "vp-control" }, "primary ", primarySel));

    const balanceOverrideIn = el("input", {
      type: "text", class: "vp-balance-override",
      placeholder: "e.g. 0.00",
      value: cfg.balance_override != null ? String(cfg.balance_override) : "",
      title: "Override the emitted balance for this group. Leave blank to use the primary's reported balance. Set to 0.00 on duplicate sibling cards to avoid multi-counting shared debt."
    });
    controlsRow.appendChild(el("label", { class: "vp-control" },
      "balance override ", balanceOverrideIn));
    body.appendChild(controlsRow);

    body.appendChild(renderTimeline(sources, win, earliest));

    // Per-source from/to inputs.
    const editor = el("div", { class: "vp-editor" });
    sources.forEach((s) => {
      const w = win[s.profile_key] || {};
      const fromIn = el("input", { type: "date", class: "vp-date", value: w.from || "" });
      const toIn   = el("input", { type: "date", class: "vp-date", value: w.to   || "" });
      const earliestHint = earliest[s.profile_key] ? `data avail from ${earliest[s.profile_key]}` : "no txns in canonical";
      editor.appendChild(el("div", { class: "vp-editor-row" },
        el("span", { class: "vp-editor-key" }, s.profile_key),
        el("label", { class: "vp-editor-field" }, "from ", fromIn),
        el("label", { class: "vp-editor-field" }, "to ",   toIn),
        el("span", { class: "vp-editor-hint" }, earliestHint)
      ));
      fromIn.dataset.source = s.profile_key; fromIn.dataset.bound = "from";
      toIn.dataset.source   = s.profile_key; toIn.dataset.bound   = "to";
    });

    const buttons = el("div", { class: "vp-buttons" });
    buttons.appendChild(el("button", {
      type: "button", class: "vp-suggest", title: "Auto-fill: primary covers from its earliest data; secondary covers up to one day before primary's earliest.",
      onclick: () => suggestWindows(group, primarySel, editor)
    }, "Suggest windows"));
    buttons.appendChild(el("button", {
      type: "button", class: "vp-preview",
      title: "Show what the merge would emit for these windows without saving.",
      onclick: () => previewGroupConfig(group, primarySel, editor, row)
    }, "Preview"));
    buttons.appendChild(el("button", {
      type: "button", class: "vp-save",
      onclick: () => saveGroupConfig(group, primarySel, editor, balanceOverrideIn)
    }, "Save"));
    buttons.appendChild(el("button", {
      type: "button", class: "vp-clear",
      title: "Clear windows back to default (primary-only).",
      onclick: () => clearGroupConfig(group)
    }, "Clear"));
    body.appendChild(editor);
    body.appendChild(buttons);

    // Placeholder for the per-group preview panel; populated on click.
    body.appendChild(el("div", { class: "vp-preview-slot" }));

    row.appendChild(body);
    return row;
  }

  function readWindowsFromEditor(editor) {
    const windows = {};
    editor.querySelectorAll(".vp-editor-row").forEach((rowEl) => {
      const inputs = rowEl.querySelectorAll("input[type=date]");
      const src = inputs[0].dataset.source;
      const from = inputs[0].value || null;
      const to   = inputs[1].value || null;
      if (from || to) windows[src] = { from, to };
    });
    return windows;
  }

  async function previewGroupConfig(group, primarySel, editor, rowEl) {
    const slot = rowEl.querySelector(".vp-preview-slot");
    slot.innerHTML = "";
    slot.appendChild(el("div", { class: "vp-preview-loading" }, "Computing preview…"));

    const payload = {
      members: group.members,
      primary: primarySel.value,
      windows: readWindowsFromEditor(editor)
    };

    let preview;
    try {
      preview = await api("/admin/api/consolidation/groups-config/preview", {
        method: "POST", body: payload
      });
    } catch (e) {
      slot.innerHTML = "";
      slot.appendChild(el("div", { class: "vp-preview-error" }, `Preview failed: ${e.message}`));
      return;
    }

    slot.innerHTML = "";
    slot.appendChild(renderGroupPreview(preview));
  }

  function renderGroupPreview(p) {
    const wrap = el("div", { class: "vp-preview-panel" });
    wrap.appendChild(el("div", { class: "vp-preview-head" },
      el("strong", {}, "Preview"),
      el("span", { class: "vp-preview-summary" },
        `→ ${p.estimated_emit_count} txns to SimpleFIN client`),
      el("span", { class: "vp-preview-primary" }, `primary: ${p.primary_pk}`)
    ));

    // Per-source contribution row
    const srcTable = el("table", { class: "vp-preview-srcs" });
    srcTable.appendChild(el("tr", {},
      el("th", {}, "source"),
      el("th", { class: "num" }, "in window"),
      el("th", { class: "num" }, "out of window")
    ));
    p.sources.forEach((s) => {
      srcTable.appendChild(el("tr", { class: s.skipped ? "vp-preview-src-skipped" : "" },
        el("td", {}, s.profile_key + (s.skipped ? " (default-empty)" : "")),
        el("td", { class: "num" }, String(s.in_window)),
        el("td", { class: "num" }, String(s.out_of_window))
      ));
    });
    wrap.appendChild(srcTable);

    // Bucket stats — operator-relevant breakdown
    const stats = p.bucket_stats || {};
    const bucketRows = [
      ["1:1 collapsed (dups absorbed)",            stats.matched_collapsed         || 0],
      ["primary-only (no secondary in bucket)",    stats.primary_only              || 0],
      ["secondary-only (gap-fill from secondary)", stats.secondary_only_emitted    || 0],
      ["secondary surplus (sec > pri in bucket)",  stats.secondary_surplus_emitted || 0],
      ["primary surplus kept (pri > sec)",         stats.primary_surplus_kept      || 0]
    ];
    const bucketTable = el("table", { class: "vp-preview-buckets" });
    bucketTable.appendChild(el("tr", {},
      el("th", {}, "bucket outcome"), el("th", { class: "num" }, "txns")
    ));
    bucketRows.forEach(([label, count]) => {
      bucketTable.appendChild(el("tr", { class: count > 0 ? "" : "vp-preview-row-zero" },
        el("td", {}, label),
        el("td", { class: "num" }, String(count))
      ));
    });
    wrap.appendChild(bucketTable);

    // Description-divergence samples
    if (p.sample_collisions && p.sample_collisions.length > 0) {
      const samp = el("div", { class: "vp-preview-samples" });
      samp.appendChild(el("div", { class: "vp-preview-samples-h" },
        `Bucket collapses where descriptions differ (first ${Math.min(p.sample_collisions.length, 5)}):`));
      p.sample_collisions.slice(0, 5).forEach((c) => {
        samp.appendChild(el("div", { class: "vp-preview-sample" },
          el("code", { class: "vp-sample-key" }, `${c.date} ${c.amount} ${c.currency}`),
          el("div", {},
            el("span", { class: "vp-sample-label" }, "primary: "),
            el("code", {}, c.primary_desc)),
          el("div", {},
            el("span", { class: "vp-sample-label" }, `${c.secondary_pk}: `),
            el("code", {}, c.secondary_desc))
        ));
      });
      wrap.appendChild(samp);
    }

    if (p.warnings && p.warnings.length > 0) {
      const warns = el("div", { class: "vp-preview-warnings" });
      p.warnings.forEach((w) => {
        warns.appendChild(el("div", { class: "vp-warning vp-warning-" + w.kind },
          el("span", { class: "vp-warning-kind" }, w.kind.replace(/_/g, " ")),
          el("span", { class: "vp-warning-msg" }, w.message)));
      });
      wrap.appendChild(warns);
    }

    return wrap;
  }

  // Render a horizontal timeline showing each source's covered range.
  // Span: from earliest known data across all sources to today. Each
  // source gets a row with a colored bar where its window covers.
  function renderTimeline(sources, windows, earliestDates) {
    const today = new Date().toISOString().slice(0, 10);
    let earliest = today;
    sources.forEach((s) => {
      const e = earliestDates[s.profile_key];
      if (e && e < earliest) earliest = e;
      const w = windows[s.profile_key];
      if (w && w.from && w.from < earliest) earliest = w.from;
    });
    if (earliest >= today) earliest = today;   // nothing to draw

    const e0 = new Date(earliest).getTime();
    const e1 = new Date(today).getTime();
    const span = Math.max(1, e1 - e0);
    const pct = (d) => Math.round((100 * (new Date(d).getTime() - e0)) / span);

    const wrap = el("div", { class: "vp-timeline" });
    sources.forEach((s) => {
      const w  = windows[s.profile_key] || { from: null, to: null };
      const ed = earliestDates[s.profile_key];
      const lane = el("div", { class: "vp-tl-lane" });
      lane.appendChild(el("span", { class: "vp-tl-label" }, s.profile_key));
      const track = el("div", { class: "vp-tl-track" });
      // Coverage hint (gray): full span between the source's earliest
      // observed data and today.
      if (ed) {
        const cov = el("div", {
          class: "vp-tl-coverage",
          style: `left: ${pct(ed)}%; right: 0%;`
        });
        track.appendChild(cov);
      }
      // Configured window (colored). If no window for this source, the
      // window-bar is omitted so the operator visually distinguishes
      // configured from default.
      const hasConfig = w.from !== null || w.to !== null;
      if (hasConfig) {
        const left  = w.from ? pct(w.from) : 0;
        const right = w.to   ? 100 - pct(w.to) : 0;
        track.appendChild(el("div", {
          class: "vp-tl-window",
          style: `left: ${left}%; right: ${right}%;`,
          title: `${w.from || "≥ start"} → ${w.to || "today"}`
        }));
      }
      lane.appendChild(track);
      wrap.appendChild(lane);
    });

    const labels = el("div", { class: "vp-tl-axis" });
    labels.appendChild(el("span", {}, earliest));
    labels.appendChild(el("span", {}, today));
    wrap.appendChild(labels);

    return wrap;
  }

  async function suggestWindows(group, primarySel, editor) {
    const earliest = group.earliest_dates || {};
    const primary = primarySel.value;
    const primaryEarliest = earliest[primary];
    if (!primaryEarliest) {
      toast.info(`No transactions in primary (${primary}) — can't auto-suggest. Set windows manually.`);
      return;
    }
    // Cutoff: primary covers [primaryEarliest, ∞), each secondary covers
    // [-∞, primaryEarliest - 1 day]. So no overlap.
    const cutoff = isoPrevDay(primaryEarliest);
    editor.querySelectorAll("input[type=date]").forEach((input) => {
      const src = input.dataset.source;
      const bound = input.dataset.bound;
      if (src === primary) {
        input.value = bound === "from" ? primaryEarliest : "";
      } else {
        input.value = bound === "from" ? "" : cutoff;
      }
    });
  }

  async function saveGroupConfig(group, primarySel, editor, balanceOverrideIn) {
    const overrideRaw = balanceOverrideIn ? balanceOverrideIn.value.trim() : "";
    const payload = {
      members: group.members,
      primary: primarySel.value,
      windows: readWindowsFromEditor(editor),
      balance_override: overrideRaw === "" ? null : overrideRaw
    };
    try {
      await api("/admin/api/consolidation/groups-config", { method: "PUT", body: payload });
      await loadVirtualProfile();
    } catch (e) {
      toast.error(`Save failed: ${e.message}`);
    }
  }

  async function clearGroupConfig(group) {
    const ok = await confirmModal({
      title: `Clear window config for ${group.id}?`,
      body:  "Falls back to primary-only behavior.",
      confirmLabel: "Clear config",
    });
    if (!ok) return;
    const payload = {
      members: group.members,
      primary: null,
      windows: {}
    };
    try {
      await api("/admin/api/consolidation/groups-config", { method: "PUT", body: payload });
      await loadVirtualProfile();
      toast.success("Window config cleared.");
    } catch (e) {
      toast.error(`Clear failed: ${e.message}`);
    }
  }

  async function createVirtualProfile() {
    try {
      const r = await api("/admin/api/consolidation/virtual-profile", { method: "POST" });
      if (r && r.created) {
        toast.success("Consolidated profile created. Mint a setup token to get the SimpleFIN URL.");
      }
      await loadVirtualProfile();
    } catch (e) {
      toast.error(`Setup failed: ${e.message}`);
    }
  }

  // Collect linked groups whose pinned primary disagrees with the
  // heuristic-suggested one. The heuristic (consolidation.rb
  // pick_primary) already deprioritizes aggregators like fintonic,
  // so this catches stale pins left over from earlier setups where
  // the operator had pinned the aggregator before adding the
  // direct-bank profile.
  function collectStalePins(linkedGroups) {
    const stale = [];
    for (const g of linkedGroups) {
      const cfg = g.config || {};
      const pinned    = cfg.primary || null;
      const suggested = g.suggested_primary ? g.suggested_primary.profile_key : null;
      if (!pinned || !suggested) continue;
      if (pinned !== suggested) {
        stale.push({ group: g, pinned, suggested });
      }
    }
    return stale;
  }

  async function resetStalePrimaries() {
    const linked = ((virtualCache && virtualCache.groups) || []).filter((g) => g.sources.length > 1);
    const stale  = collectStalePins(linked);
    if (!stale.length) {
      toast.info("No stale primaries — all groups already use the suggested source.");
      return;
    }

    const diffList = el("ul", { style: "margin:0; padding-left: 18px; font-size: var(--fs-sm); max-height: 240px; overflow: auto" });
    stale.forEach((s) => {
      diffList.appendChild(el("li", {},
        el("code", {}, s.group.id), ": ",
        el("strong", {}, s.pinned), " → ", el("strong", {}, s.suggested),
      ));
    });

    const ok = await confirmModal({
      title: `Reset ${stale.length} stale primar${stale.length === 1 ? "y" : "ies"}?`,
      body:  el("div", {},
        el("p", { style: "margin:0 0 8px" },
          "Each group below has a pinned primary that disagrees with the heuristic suggestion. ",
          "Clearing the pin lets the heuristic take over (it prefers real banks over aggregators)."),
        diffList,
        el("p", { style: "margin:8px 0 0; font-size: var(--fs-xs); color: var(--fg-subtle)" },
          "Per-source windows and balance overrides are preserved. Downstream SimpleFIN clients ",
          "may see a new account id where the primary changes and need to be re-linked."),
      ),
      confirmLabel: "Reset primaries",
    });
    if (!ok) return;

    let updated = 0;
    let failed  = 0;
    for (const s of stale) {
      const cfg = s.group.config || {};
      const payload = {
        members: s.group.members,
        primary: null, // clear pin; heuristic resolves to the suggested source
        windows: cfg.windows || {},
        balance_override: cfg.balance_override == null ? null : cfg.balance_override,
      };
      try {
        await api("/admin/api/consolidation/groups-config", { method: "PUT", body: payload });
        updated += 1;
      } catch (e) {
        failed += 1;
        console.error(`reset primary failed for ${s.group.id}:`, e);
      }
    }
    await loadVirtualProfile();
    if (failed) {
      toast.error(`Reset ${updated}/${stale.length} primaries; ${failed} failed (check console).`);
    } else {
      toast.success(`Reset ${updated} primar${updated === 1 ? "y" : "ies"} to heuristic suggestion.`);
    }
  }


  async function mintVirtualSetupToken() {
    try {
      const r = await api(`/admin/api/profiles/consolidated/setup-token`, { method: "POST" });
      if (r && r.setup_token) {
        // Reuse the existing setup-token panel if present.
        const panel = document.getElementById("setup-token-panel");
        const value = document.getElementById("setup-token-value");
        if (panel && value) {
          value.value = r.setup_token;
          panel.classList.remove("hidden");
          panel.scrollIntoView({ behavior: "smooth", block: "center" });
        } else {
          prompt("Setup token (copy now — single-use, 10 min TTL):", r.setup_token);
        }
      }
    } catch (e) {
      toast.error(`Token mint failed: ${e.message}`);
    }
  }

  const vpBtn = document.getElementById("virtual-profile-create-btn");
  if (vpBtn) vpBtn.addEventListener("click", createVirtualProfile);

  const vpResetBtn = document.getElementById("virtual-profile-reset-primaries-btn");
  if (vpResetBtn) vpResetBtn.addEventListener("click", resetStalePrimaries);

  function renderFreentonicHealth(freentonic) {
    const wrap  = document.getElementById("freentonic-health");
    const state = document.getElementById("freentonic-state");
    if (!wrap || !state) return;
    if (!freentonic || !freentonic.state) {
      wrap.hidden = true;
      return;
    }
    wrap.hidden = false;
    state.textContent = freentonic.state;
    state.className = `health-state health-${freentonic.state}`;
    state.title = freentonic.last_error
      ? `${freentonic.last_error} (last probe ${freentonic.last_probe_at || "n/a"})`
      : `last probe ${freentonic.last_probe_at || "n/a"}`;
  }

  async function probeFreentonicHealth() {
    const btn = document.getElementById("freentonic-refresh");
    if (btn) { btn.disabled = true; btn.classList.add("spinning"); }
    try {
      const data = await api("/admin/api/freentonic/health/probe", { method: "POST" });
      if (data) {
        setState("freentonicHealth", data);
        renderFreentonicHealth(data);
      }
    } catch (e) {
      console.error(e);
    } finally {
      if (btn) { btn.disabled = false; btn.classList.remove("spinning"); }
    }
  }

  function renderActiveJob(job) {
    const existing = document.getElementById("active-job-banner");
    if (!job) {
      if (existing) existing.remove();
      stopLiveLog();
      return;
    }

    // Same run still going? Don't rebuild. Replacing the banner every
    // 2 s would tear down the live-log <pre> (losing accumulated
    // output and the open/closed toggle) AND the VNC iframe (severing
    // its WebSocket every poll). Mirrors renderProfileRow's diff
    // pattern. New run_id => fresh banner.
    if (existing && existing.dataset.runId === job.run_id) {
      // Banner DOM is stable, but prompts come and go mid-run — keep
      // polling on the same 2 s cadence as the parent refresh().
      pollPrompts(job.profile_key, job.run_id);
      return;
    }

    const startedAt = job.started_at ? new Date(job.started_at).toLocaleTimeString() : "—";
    const banner = el("section", { id: "active-job-banner", class: "panel" },
      el("h2", {}, job.recording
          ? `Recording: ${job.profile_key}`
          : job.interactive
            ? `Browsing: ${job.profile_key}`
            : `Running: ${job.profile_key}`),
      el("div", { class: "profile-meta" },
        el("span", {}, `run ${job.run_id}`),
        el("span", {}, `started ${startedAt}`),
        el("span", {},
          job.recording ? "recording (no scrape, capturing actions)"
          : job.interactive ? "interactive (no scrape)"
          : "syncing"),
        el("span", {}, "VNC enabled"),
        job.trigger ? el("span", {}, `trigger: ${job.trigger}`) : null
      ),
      // Inline noVNC viewer. Now same-origin (proxied through Caddy
      // at /novnc/) so HTTPS pages can embed it without mixed-content
      // blocking. Collapsed by default for hands-off syncs; expanded
      // for interactive/recording runs where the operator is driving.
      // pollPrompts() force-opens it the moment a 2FA/SMS prompt
      // appears so the operator can act without hunting for it. The
      // iframe survives across status polls because the banner above
      // short-circuits when run_id matches (no WebSocket teardown).
      job.vnc_url
        ? el("details",
            (job.interactive || job.recording)
              ? { class: "vnc-details", open: "" }
              : { class: "vnc-details" },
            el("summary", { class: "vnc-summary" },
              "Live VNC",
              el("a", {
                href: job.vnc_url,
                target: "_blank",
                rel: "noopener noreferrer",
                class: "vnc-popout",
                // The anchor sits inside <summary>; a click would
                // bubble up and toggle the <details>, collapsing the
                // inline iframe — and on some browsers the toggle
                // handler ends up swallowing the navigation entirely
                // so nothing opens. Stop the bubble so only the
                // default-link action fires.
                onclick: (e) => e.stopPropagation(),
              }, "↗ open in tab")
            ),
            el("iframe", {
              src: job.vnc_url,
              title: "Live freentonic VNC",
              class: "vnc-iframe",
              allow: "clipboard-read; clipboard-write"
            })
          )
        : null,
      el("div", { class: "row" },
        el("button", {
          id: "active-job-log-toggle",
          onclick: () => toggleLiveLog(job.profile_key, job.run_id)
        }, "Expand log"),
        // "Stop browsing" only for interactive runs — regular syncs
        // shouldn't be cancellable from this banner (the workflow is
        // mid-scrape; cancelling probably leaves bank state in a
        // weird place). For interactive, the cancel IS how the
        // operator says "I'm done, close Chrome."
        job.recording
          ? el("button", {
              class: "primary",
              onclick: () => stopRecording(job.profile_key, job.run_id),
              title: "End the recording — closes Chrome and shows the captured transcript"
            }, "Stop & show recording")
          : job.interactive
            ? el("button", {
                class: "primary",
                onclick: () => stopBrowse(job.run_id),
                title: "End the browse session — closes Chrome cleanly and resets the profile to idle"
              }, "Stop browsing")
            : null
      ),
      // Prompts host — rendered empty; pollPrompts() fills it in when
      // the workflow pauses on a 2FA / SMS / external-confirm step. We
      // place it above the live-log toggle so the operator can't miss
      // it while the run is mid-flight.
      el("div", { id: "active-job-prompts", class: "prompt-card-host" }),
      // Always-on log preview. Defaults to compact (last few lines, no
      // scroll) so the operator can glance at progress without
      // expanding anything; the toggle button above flips it to full
      // scrollable view. Polling starts unconditionally below.
      el("pre", { id: "active-job-log", class: "run-log compact" }, "Loading…")
    );
    banner.dataset.runId = job.run_id;

    if (existing) {
      existing.replaceWith(banner);
    } else {
      document.querySelector("main").prepend(banner);
    }
    // Kick off the first prompt poll right after mounting the banner
    // so a workflow that pauses immediately doesn't wait 2 s before
    // surfacing the form.
    pollPrompts(job.profile_key, job.run_id);
    // Live log polls unconditionally — the inline tail above always
    // shows the last few lines; toggling just resizes the view.
    startLiveLog(job.profile_key, job.run_id);
  }

  // Poll for any prompts the freentonic runner is paused on. Called
  // every refresh tick (2 s) while a job is active, regardless of
  // whether the live-log panel is open — the operator should see a
  // 2FA prompt the moment freentonic emits it. The diff guard via
  // dataset.activePrompt keeps a half-typed code from being clobbered
  // by the next poll.
  async function pollPrompts(profileKey, runId) {
    const host = document.getElementById("active-job-prompts");
    if (!host) return;
    let prompts;
    try {
      const data = await api(
        `/admin/api/profiles/${encodeURIComponent(profileKey)}/runs/${encodeURIComponent(runId)}/prompts`
      );
      prompts = (data && data.prompts) || [];
    } catch (e) {
      console.error(e);
      return;
    }
    if (!prompts.length) {
      if (host.dataset.activePrompt) {
        host.replaceChildren();
        host.dataset.activePrompt = "";
      }
      return;
    }
    // Freentonic exposes one prompt at a time per run; if that ever
    // changes we'd render the head and queue the rest.
    const prompt = prompts[0];
    if (host.dataset.activePrompt === prompt.prompt_id) return;
    host.dataset.activePrompt = prompt.prompt_id;
    host.replaceChildren(buildPromptCard(profileKey, runId, prompt));
    // A fresh prompt means the workflow is paused waiting on the
    // operator (SMS code, 2FA, captcha…). The VNC viewer is collapsed
    // by default for hands-off syncs — pop it open so the operator
    // can see what the bank is asking for without an extra click.
    const vncDetails = document.querySelector("#active-job-banner .vnc-details");
    if (vncDetails) vncDetails.open = true;
  }

  function buildPromptCard(profileKey, runId, prompt) {
    const status = el("p", { class: "prompt-card-status" }, "");
    // `await` is a self-resolving wait (e.g. a phone push that flips the
    // browser URL): the card clears on its own when the runner withdraws the
    // prompt, so it reads as a "waiting on you" state rather than a hard
    // pause. input/confirm genuinely block the run on operator input.
    const isAwait = prompt.kind === "await";
    const card = el("div", {
      class: isAwait ? "prompt-card prompt-card--await" : "prompt-card",
      "data-prompt-id": prompt.prompt_id
    });
    const titleText = isAwait ? "Waiting for your approval" : "Workflow paused — input needed";
    card.appendChild(isAwait
      ? el("h3", { class: "prompt-card-title" },
          el("span", { class: "prompt-card-spinner", "aria-hidden": "true" }), titleText)
      : el("h3", { class: "prompt-card-title" }, titleText));
    if (prompt.message) {
      card.appendChild(el("p", { class: "prompt-card-message" }, prompt.message));
    }

    if (prompt.kind === "input") {
      const input = el("input", {
        type: prompt.mask ? "password" : "text",
        // OTPs are virtually always digits; the hint helps mobile
        // browsers pop a numeric keypad. Browsers ignore on desktop.
        inputmode: "numeric",
        autocomplete: "one-time-code",
        class: "prompt-card-input",
        placeholder: "Enter the code"
      });
      const submitBtn = el("button", { type: "submit", class: "primary" }, "Submit");
      const form = el("form", { class: "prompt-card-form" }, input, submitBtn);
      form.addEventListener("submit", (e) => {
        e.preventDefault();
        const value = (input.value || "").trim();
        if (!value) {
          status.textContent = "Enter a value before submitting.";
          return;
        }
        submitPromptAnswer({
          profileKey, runId, promptId: prompt.prompt_id,
          body: { kind: "input", value },
          status, disable: [submitBtn, input]
        });
      });
      card.appendChild(form);
      // Autofocus so the operator can start typing the code without
      // hunting for the field. Wrapped in setTimeout so the focus
      // happens after the host's replaceChildren mounts the input.
      setTimeout(() => { try { input.focus(); } catch (_) {} }, 0);
    } else if (prompt.kind === "confirm") {
      const btn = el("button", { type: "button", class: "primary" }, "I approved");
      btn.addEventListener("click", () => {
        submitPromptAnswer({
          profileKey, runId, promptId: prompt.prompt_id,
          body: { kind: "confirm" },
          status, disable: [btn]
        });
      });
      card.appendChild(btn);
    } else if (prompt.kind === "await") {
      // The run continues by itself the moment the approval lands — the
      // operator usually never touches this. The button is only for the
      // rare case where the redirect is slow and they want to nudge it.
      const btn = el("button", { type: "button", class: "prompt-card-await-btn" },
        "Already approved? Continue");
      btn.addEventListener("click", () => {
        submitPromptAnswer({
          profileKey, runId, promptId: prompt.prompt_id,
          body: { kind: "await" },
          status, disable: [btn]
        });
      });
      card.appendChild(btn);
    } else {
      card.appendChild(el("p", { class: "prompt-card-status" },
        `Unknown prompt kind: ${prompt.kind}`));
    }

    if (prompt.expires_at) {
      const exp = new Date(prompt.expires_at);
      if (!Number.isNaN(exp.getTime())) {
        card.appendChild(el("p", { class: "prompt-card-expires profile-meta" },
          `Expires at ${exp.toLocaleTimeString()}`));
      }
    }
    card.appendChild(status);
    return card;
  }

  async function submitPromptAnswer({ profileKey, runId, promptId, body, status, disable }) {
    disable.forEach((el) => { el.disabled = true; });
    status.textContent = "";
    let res;
    try {
      // Use raw fetch (not api()) so we can branch on 400/409/410 and
      // surface the freentonic-side reason inline rather than throwing.
      res = await fetch(
        `/admin/api/profiles/${encodeURIComponent(profileKey)}/runs/${encodeURIComponent(runId)}/prompts/${encodeURIComponent(promptId)}`,
        {
          credentials: "same-origin",
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body)
        }
      );
    } catch (err) {
      status.textContent = `Submit failed: ${err.message}`;
      disable.forEach((el) => { el.disabled = false; });
      return;
    }

    if (res.ok) {
      // Clear the card immediately so the operator sees the run resume.
      // The next pollPrompts tick (≤ 2 s) will either keep it empty
      // (run advanced past the prompt) or re-render with the next
      // prompt.
      const host = document.getElementById("active-job-prompts");
      if (host) {
        host.replaceChildren();
        host.dataset.activePrompt = "";
      }
      // Force-tail the live log if it's open, so the operator sees the
      // step that consumed the prompt without waiting for the next tick.
      fetchLiveLog();
      return;
    }

    let reason = `freentonic returned ${res.status}`;
    try {
      const j = await res.json();
      if (j && j.error) reason = j.error;
    } catch (_) { /* non-JSON body, fall back to status */ }
    status.textContent = reason;
    // 409 / 410 are terminal for this prompt; the next poll will
    // either remove the card (freentonic moved on) or re-issue a new
    // prompt_id. Re-enable controls in case the operator wants to
    // retry submission with a different value (matters for 400, not
    // for 409/410).
    disable.forEach((el) => { el.disabled = false; });
  }

  // Number of trailing lines shown in the compact preview. Small
  // enough to stay below the VNC viewer without scrolling the banner;
  // large enough that the operator can see "thinking…" progress.
  const LIVE_LOG_TAIL_LINES = 5;

  function startLiveLog(profileKey, runId) {
    if (liveLogTimer && liveLogRunId === runId) return;
    if (liveLogTimer) clearInterval(liveLogTimer);
    liveLogProfile = profileKey;
    liveLogRunId = runId;
    liveLogOffset = 0;
    liveLogBuffer = "";
    liveLogPrimed = false;
    liveLogTruncated = false;
    fetchLiveLog();
    liveLogTimer = setInterval(fetchLiveLog, 2000);
  }

  function toggleLiveLog() {
    const pre = document.getElementById("active-job-log");
    if (!pre) return;
    const nowCompact = pre.classList.toggle("compact");
    const btn = document.getElementById("active-job-log-toggle");
    if (btn) btn.textContent = nowCompact ? "Expand log" : "Collapse log";
    // Re-render from the buffer so the resize swaps tail/full views
    // instantly — no need to wait for (or trigger) a network poll.
    renderLiveLog(pre);
  }

  function renderLiveLog(pre) {
    const full = liveLogBuffer.replace(/\s+$/, "");
    if (pre.classList.contains("compact")) {
      const lines = full ? full.split("\n") : [];
      pre.textContent = lines.slice(-LIVE_LOG_TAIL_LINES).join("\n") || "(log is empty so far)";
    } else {
      const prefix = liveLogTruncated ? "…(earlier output truncated)\n" : "";
      pre.textContent = prefix + (full || "(log is empty so far)");
      pre.scrollTop = pre.scrollHeight;
    }
  }

  async function fetchLiveLog() {
    if (!liveLogRunId || !liveLogProfile) return;
    const pre = document.getElementById("active-job-log");
    if (!pre) { stopLiveLog(); return; }
    const base = `/admin/api/profiles/${encodeURIComponent(liveLogProfile)}/runs/${encodeURIComponent(liveLogRunId)}/log`;
    try {
      if (!liveLogPrimed) {
        // First poll: pull the current tail in one shot so the operator sees
        // recent context immediately, then stream forward from its end.
        const data = await api(base);
        liveLogBuffer = data.log || "";
        liveLogTruncated = !!data.truncated;
        liveLogOffset = typeof data.size === "number" ? data.size : liveLogBuffer.length;
        liveLogPrimed = true;
      } else {
        // Steady state: fetch only the bytes appended since last time.
        const data = await api(`${base}?offset=${liveLogOffset}`);
        if (data.chunk) liveLogBuffer += data.chunk;
        if (typeof data.offset === "number") liveLogOffset = data.offset;
      }
      renderLiveLog(pre);
    } catch (e) {
      pre.textContent = `Log fetch failed: ${e.message}`;
    }
  }

  function stopLiveLog() {
    if (liveLogTimer) {
      clearInterval(liveLogTimer);
      liveLogTimer = null;
    }
    liveLogRunId = null;
    liveLogProfile = null;
    liveLogOffset = 0;
    liveLogBuffer = "";
    liveLogPrimed = false;
    liveLogTruncated = false;
  }

  async function loadWorkflows() {
    if (workflowsCache) return workflowsCache;
    const data = await api("/admin/api/workflows");
    workflowsCache = data.workflows;
    workflowsMeta  = data.meta || null;
    setState("workflows", { list: workflowsCache, meta: workflowsMeta });
    renderWorkflowsMeta();
    return workflowsCache;
  }

  function renderWorkflowsMeta() {
    const el = document.getElementById("workflows-meta");
    if (!el) return;
    if (!workflowsMeta) {
      el.hidden = true;
      return;
    }
    el.hidden = false;
    const ref = workflowsMeta.ref || "?";
    const commit = (workflowsMeta.commit || "").slice(0, 7);
    const repo = workflowsMeta.repo || "";
    const fetched = workflowsMeta.fetched_at
      ? new Date(workflowsMeta.fetched_at).toLocaleString()
      : "";
    el.textContent = commit
      ? `workflows: ${repo} @ ${ref} (${commit})`
      : `workflows: ${repo} @ ${ref}`;
    el.title = `Last refresh: ${fetched}\nProviders: ${(workflowsMeta.providers || []).join(", ")}`;
  }

  async function openNewProfile() {
    const sel = $("#new-profile-form [name=workflow]");
    sel.innerHTML = "";
    const wfs = await loadWorkflows();
    for (const wf of wfs) {
      sel.appendChild(el("option", { value: wf.workflow }, workflowLabel(wf.workflow)));
    }
    newPanel.classList.remove("hidden");
    revealLegacyPanel(newPanel);
  }

  // Reveal helper: legacy reveal-and-fill panels (new profile,
  // credentials, setup-token) live inside the manage route-view.
  // If the operator triggered one from elsewhere (e.g. the detail
  // page), bounce them to manage so the panel is actually visible,
  // then scroll it into view.
  function revealLegacyPanel(panel) {
    if (!panel) return;
    if (!window.location.hash.startsWith("#/manage")) {
      navigate("#/manage");
    }
    // Defer the scroll until after the route swap paints.
    requestAnimationFrame(() => {
      try { panel.scrollIntoView({ behavior: "smooth", block: "start" }); }
      catch (_) { /* older browsers — fine */ }
    });
  }

  $("#new-profile-btn").addEventListener("click", openNewProfile);
  $("#new-profile-cancel").addEventListener("click", () => newPanel.classList.add("hidden"));
  $("#sync-all-btn").addEventListener("click", syncAll);

  $("#new-profile-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const form = new FormData(e.target);
    try {
      const interval = parseInt(form.get("sync_interval_seconds"), 10);
      const maxLb    = parseInt(form.get("max_lookback_days"), 10);
      const overlap  = parseInt(form.get("lookback_overlap_days"), 10);
      await api("/admin/api/profiles", {
        method: "POST",
        body: {
          profile_key: form.get("profile_key"),
          display_name: form.get("display_name"),
          workflow: form.get("workflow"),
          lookback_days: parseInt(form.get("lookback_days"), 10) || 30,
          max_lookback_days: Number.isFinite(maxLb) && maxLb > 0 ? maxLb : 365,
          lookback_mode: form.get("lookback_mode") || "incremental",
          lookback_overlap_days: Number.isFinite(overlap) && overlap >= 0 ? overlap : 10,
          sync_interval_seconds: Number.isFinite(interval) && interval > 0 ? interval : null,
        },
      });
      newPanel.classList.add("hidden");
      e.target.reset();
      refresh();
      toast.success("Profile created. Add credentials, then click Sync now to start the first run.");
    } catch (err) {
      toast.error(`Create failed: ${err.message}`);
    }
  });

  async function openCredentials(profile) {
    const wfs = await loadWorkflows();
    const wf = wfs.find((w) => w.workflow === profile.workflow);
    const secrets = wf ? wf.secrets : [];
    $("#cred-profile").textContent = profile.profile_key;
    const form = $("#credentials-form");
    form.innerHTML = "";
    if (!secrets.length) {
      form.appendChild(el("p", {}, "This workflow does not declare any secrets."));
    } else {
      for (const name of secrets) {
        form.appendChild(el("label", {},
          name,
          el("input", { name, type: "password", autocomplete: "off" })
        ));
      }
      form.appendChild(el("div", { class: "row" },
        el("button", { type: "submit", class: "primary" }, "Save"),
        el("button", { type: "button", onclick: () => credPanel.classList.add("hidden") }, "Cancel")
      ));
      form.onsubmit = async (e) => {
        e.preventDefault();
        const payload = {};
        for (const name of secrets) {
          const val = form.elements[name].value;
          if (val) payload[name] = val;
        }
        try {
          await api(`/admin/api/profiles/${encodeURIComponent(profile.profile_key)}/credentials`, {
            method: "POST",
            body: { secrets: payload },
          });
          credPanel.classList.add("hidden");
          refresh();
          toast.success("Credentials saved.");
        } catch (err) {
          toast.error(`Save failed: ${err.message}`);
        }
      };
    }
    credPanel.classList.remove("hidden");
    revealLegacyPanel(credPanel);
  }

  async function rebuildHistory(profile) {
    const stats = profile.history;
    const current = stats && stats.txn_count
      ? `Currently ${stats.txn_count.toLocaleString()} txns, last ${stats.last_tx_date || "?"}.`
      : "History is empty.";
    const ok = await confirmModal({
      title: `Rebuild history for ${profile.profile_key}?`,
      body:  `${current} Drops history.json and replays every on-disk run canonical to reconstruct it. No bank scrape, no network. Pre-existing canonicals are kept.`,
      confirmLabel: "Rebuild history",
    });
    if (!ok) return;
    try {
      const data = await api(
        `/admin/api/profiles/${encodeURIComponent(profile.profile_key)}/history/rebuild`,
        { method: "POST" }
      );
      toast.success(`Rebuilt: ${data.txn_count.toLocaleString()} txns from runs on disk.`);
      refresh();
    } catch (e) { toast.error(`Rebuild failed: ${e.message}`); }
  }

  async function resetHistory(profile) {
    const stats = profile.history;
    if (!stats || !stats.txn_count) {
      toast.info("History is already empty for this profile.");
      return;
    }
    const ok = await confirmModal({
      title: `Reset history for ${profile.profile_key}?`,
      body:  `Wipes ${stats.txn_count.toLocaleString()} accumulated txns. ` +
             `Next sync will cold-start a deep backfill (up to max_lookback_days = ${profile.max_lookback_days || 365}). ` +
             `Per-run canonical snapshots on disk are NOT deleted — you can recover via "Rebuild history".`,
      confirmLabel: "Reset history",
      danger: true,
    });
    if (!ok) return;
    try {
      await api(
        `/admin/api/profiles/${encodeURIComponent(profile.profile_key)}/history`,
        { method: "DELETE" }
      );
      toast.success("History reset. Next sync will deep-backfill.");
      refresh();
    } catch (e) { toast.error(`Reset failed: ${e.message}`); }
  }

  async function mintSetupToken(key) {
    try {
      const data = await api(`/admin/api/profiles/${encodeURIComponent(key)}/setup-token`, { method: "POST" });
      tokenValue.value = data.setup_token;
      tokenPanel.classList.remove("hidden");
      revealLegacyPanel(tokenPanel);
    } catch (e) { toast.error(e.message); }
  }

  $("#copy-setup-token").addEventListener("click", () => {
    tokenValue.select();
    document.execCommand("copy");
  });

  // PATCH a profile's sync_interval_seconds. nextValue === null disables
  // auto-sync (manual only); a positive integer >= 300 (enforced by the
  // backend) sets the cadence. Refresh after success so the detail view
  // re-renders with the new "next auto-sync in ~Xh" hint.
  async function saveSchedule(profileKey, nextValue) {
    await api(`/admin/api/profiles/${encodeURIComponent(profileKey)}`, {
      method: "PATCH",
      body: { sync_interval_seconds: nextValue },
    });
    refresh();
  }

  // Bulk-enqueue every eligible source profile. The scheduler runs them
  // one at a time — banks dislike concurrent automation — so this is
  // just a convenience over click-syncing each row. Toast summarizes
  // the partition so the operator sees skipped profiles (missing creds,
  // missing access URL, already queued).
  async function syncAll() {
    try {
      const data = await api("/admin/api/sync-all", { method: "POST" });
      const enq = (data && data.enqueued) || [];
      const skipped = (data && data.skipped) || [];
      const skipDesc = skipped.length
        ? ` Skipped ${skipped.length}: ${skipped.slice(0, 3).map((s) => `${s.profile_key} (${s.reason})`).join(", ")}${skipped.length > 3 ? "…" : ""}`
        : "";
      if (enq.length === 0 && skipped.length === 0) {
        toast.info("No source profiles to sync.");
      } else if (enq.length === 0) {
        toast.info(`Nothing enqueued.${skipDesc}`);
      } else {
        toast.success(`Enqueued ${enq.length}: ${enq.join(", ")}.${skipDesc}`);
      }
      refresh();
    } catch (e) {
      toast.error(`Sync all failed: ${e.message}`);
    }
  }

  async function triggerSync(profile, headed) {
    // Ask for a per-run lookback override before kicking off the sync.
    // Some providers (e.g. Unicaja) need a one-off long backfill that
    // doesn't belong in the profile's standing settings.
    //
    // Behavior depends on lookback_mode:
    //   - "incremental" (default): empty input. Pressing Enter without
    //     typing → no override, the scheduler computes the window from
    //     the durable history (days_since_last_tx + overlap).
    //   - "fixed": seed with lookback_days so one Enter press preserves
    //     the legacy behavior of "use the profile default".
    const mode     = profile.lookback_mode || "incremental";
    const fallback = profile.lookback_days || 30;
    const ceiling  = profile.max_lookback_days || 365;
    const overlap  = profile.lookback_overlap_days || 10;
    const hint = (mode === "incremental")
      ? `(leave blank for incremental — auto-computed from history + ${overlap}d overlap, max ${ceiling})`
      : `(profile default: ${fallback}, max: ${ceiling})`;
    const seed = (mode === "incremental") ? "" : String(fallback);
    const raw = window.prompt(
      `Sync ${profile.profile_key}\n\n` +
      `How many days of history to fetch?\n` +
      hint,
      seed
    );
    if (raw === null) return; // operator cancelled
    const trimmed = String(raw).trim();
    let lookback = null;
    if (trimmed !== "") {
      lookback = parseInt(trimmed, 10);
      if (!Number.isFinite(lookback) || lookback <= 0) {
        toast.error("Lookback must be a positive integer (or empty for incremental).");
        return;
      }
      if (lookback > ceiling) {
        toast.error(`Lookback ${lookback} exceeds max_lookback_days (${ceiling}). ` +
              `Raise max_lookback_days first if you really need a longer window.`);
        return;
      }
    }
    try {
      const body = { headed };
      if (lookback !== null) body.lookback = lookback;
      const data = await api(`/admin/api/profiles/${encodeURIComponent(profile.profile_key)}/sync`, {
        method: "POST",
        body,
      });
      if (headed && data && data.vnc_password) {
        showVncInstructions(data);
      }
      refresh();
    } catch (e) { toast.error(e.message); }
  }

  function showVncInstructions(data) {
    // Drop a transient card above the profiles list with the one-shot VNC
    // password + a direct noVNC link. Persists until the operator dismisses
    // it — a polling refresh must not wipe it out.
    const existing = document.getElementById("vnc-banner");
    if (existing) existing.remove();
    const banner = el("section", { id: "vnc-banner", class: "panel" },
      el("h2", {}, `Re-authenticate ${data.profile_key} via VNC`),
      el("p", {},
        "A headed sync has been queued. Open noVNC in a new tab and paste this one-shot password — it is discarded as soon as the sync finishes:"
      ),
      el("pre", { class: "vnc-password" }, data.vnc_password),
      data.vnc_url
        ? el("p", {},
            el("a", { href: data.vnc_url, target: "_blank", rel: "noreferrer" }, "Open noVNC"),
            " (autoconnect uses the password above)"
          )
        : null,
      el("button", { onclick: () => banner.remove() }, "Dismiss")
    );
    document.querySelector("main").prepend(banner);
  }

  async function triggerBrowse(key) {
    try {
      const data = await api(`/admin/api/profiles/${encodeURIComponent(key)}/browse`, { method: "POST" });
      // Mirror triggerSync: surface the VNC password + noVNC link
      // immediately as a fallback (the inline active-job banner takes
      // up to one status-poll cycle to appear). Without this, clicking
      // Browse looks like it did nothing for ~2 s — the most common
      // "Browse not working" report turned out to be impatience here.
      if (data && data.vnc_password) {
        showVncInstructions(data);
      }
      toast.info(`Browse session queued for ${key}. VNC iframe will appear above shortly.`);
      refresh();
    } catch (e) { toast.error(`Browse failed: ${e.message}`); }
  }

  async function stopBrowse(runId) {
    try {
      await api(`/admin/api/runs/${encodeURIComponent(runId)}/cancel`, { method: "POST" });
      refresh();
    } catch (e) { toast.error(`Stop browsing failed: ${e.message}`); }
  }

  async function triggerRecord(key) {
    try {
      await api(`/admin/api/profiles/${encodeURIComponent(key)}/record`, { method: "POST" });
      refresh();
    } catch (e) { toast.error(`Record failed: ${e.message}`); }
  }

  async function stopRecording(profileKey, runId) {
    try {
      await api(`/admin/api/runs/${encodeURIComponent(runId)}/cancel`, { method: "POST" });
    } catch (e) {
      toast.error(`Stop recording failed: ${e.message}`);
      return;
    }
    // Give freentonic a beat to flush the JSONL on its way out — the
    // recorder writes one trailing recorder_stopped event in its
    // `close`. 500 ms is empirically enough; if not, the user can
    // re-fetch by re-clicking Record (the panel re-renders).
    await new Promise((r) => setTimeout(r, 500));
    let data;
    try {
      data = await api(
        `/admin/api/profiles/${encodeURIComponent(profileKey)}/runs/${encodeURIComponent(runId)}/recording`
      );
    } catch (e) {
      toast.error(`Recording fetch failed: ${e.message}. The session ended; click Runs to see the entry.`);
      refresh();
      return;
    }
    showRecordingPanel(profileKey, runId, data);
    refresh();
  }

  async function showRunRecording(profileKey, runId) {
    let data;
    try {
      data = await api(
        `/admin/api/profiles/${encodeURIComponent(profileKey)}/runs/${encodeURIComponent(runId)}/recording`
      );
    } catch (e) {
      toast.error(`Recording fetch failed: ${e.message}`);
      return;
    }
    showRecordingPanel(profileKey, runId, data);
    // Scroll to the panel — it mounts at the top of <main>, so without
    // this the operator's view stays put on the run row they clicked
    // and the panel arrives off-screen.
    const panel = document.getElementById("recording-panel");
    if (panel) panel.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function showRecordingPanel(profileKey, runId, data) {
    const existing = document.getElementById("recording-panel");
    if (existing) existing.remove();

    const events = (data && data.events) || [];
    const useful = events.filter((e) =>
      e && (e.kind === "click" || e.kind === "fill" || e.kind === "submit" || e.kind === "navigate")
    );

    const panel = el("section", { id: "recording-panel", class: "panel" },
      el("div", { class: "panel-head" },
        el("h2", {}, `Recording transcript: ${profileKey}`),
        el("div", { class: "panel-head-actions" },
          el("button", { onclick: () => panel.remove() }, "Dismiss")
        )
      ),
      el("p", { class: "profile-meta" },
        `${useful.length} action${useful.length === 1 ? "" : "s"} captured · ` +
        `run ${runId} · ${data && data.size ? data.size + " bytes" : "size n/a"}`
      )
    );

    if (!useful.length) {
      panel.appendChild(el("p", {},
        "No actions captured. The probe was injected but no clicks / fills / submits / navigations fired. " +
        "If you did interact with the page, check that the workflow's `connect` phase navigates somewhere " +
        "before the recorder gives up — the JSONL only arrives once Chrome reaches a real page."
      ));
    } else {
      const list = el("ol", { class: "recording-list" });
      for (const ev of useful) {
        list.appendChild(renderRecordingEvent(ev));
      }
      panel.appendChild(list);
    }

    document.querySelector("main").prepend(panel);
  }

  function renderRecordingEvent(ev) {
    const sel = ev.selector || "";
    const yamlLine = recordingYamlLine(ev);
    const cssLine = sel ? `${ev.kind} ${sel}` : ev.kind;
    const item = el("li", { class: "recording-item" + (ev.needs_review ? " needs-review" : "") },
      el("div", { class: "recording-summary" },
        el("span", { class: `recording-kind kind-${ev.kind}` }, ev.kind),
        ev.text ? el("span", { class: "recording-label" }, `"${ev.text}"`) : null,
        ev.tag ? el("span", { class: "profile-meta" }, `<${ev.tag}>`) : null,
        ev.selector_strategy ? el("span", { class: "profile-meta" }, `via ${ev.selector_strategy}`) : null,
        ev.needs_review ? el("span", { class: "needs-review-pill" }, "review selector") : null
      ),
      ev.url && ev.kind === "navigate"
        ? el("div", { class: "recording-url" }, ev.url)
        : null,
      sel ? el("code", { class: "recording-css" }, sel) : null,
      yamlLine ? el("code", { class: "recording-yaml" }, yamlLine) : null,
      el("div", { class: "row" },
        sel ? el("button", { onclick: () => copyToClipboard(sel) }, "Copy CSS") : null,
        yamlLine ? el("button", { onclick: () => copyToClipboard(yamlLine) }, "Copy YAML line") : null
      )
    );
    return item;
  }

  function recordingYamlLine(ev) {
    if (!ev) return "";
    const sel = ev.selector || "";
    switch (ev.kind) {
      case "click":
        // Prefer the freentonic-flavored click_text when we have a
        // visible label and the underlying element is buttonish; that
        // selector style is more durable than CSS through bank UI
        // refreshes. Fall back to a plain click on the CSS selector.
        if (ev.text && (ev.tag === "button" || ev.tag === "a" || ev.role === "button")) {
          return `- action: click_text\n  text: "${ev.text}"`;
        }
        return sel ? `- action: click\n  selector: ${quoteIfNeeded(sel)}` : "";
      case "fill":
        if (!sel) return "";
        if (ev.mask) {
          return `- action: fill\n  selector: ${quoteIfNeeded(sel)}\n  value: secret(REPLACE_ME)`;
        }
        return `- action: fill\n  selector: ${quoteIfNeeded(sel)}\n  value: ${quoteIfNeeded(ev.value || "")}`;
      case "submit":
        return sel ? `- action: click\n  selector: ${quoteIfNeeded(sel)}` : "";
      case "navigate":
        return ev.url ? `- action: wait_url\n  includes: ${quoteIfNeeded(urlPathHint(ev.url))}` : "";
      default:
        return "";
    }
  }

  async function clearSession(key) {
    const ok = await confirmModal({
      title: `Wipe Chrome session for ${key}?`,
      body:  "Reversible — next sync will re-authenticate from scratch. " +
             "Use this before a manual VNC warm-up if anti-bot detection " +
             "may be flagging a stale fingerprint.",
      confirmLabel: "Wipe session",
      danger: true,
    });
    if (!ok) return;
    try {
      const data = await api(`/admin/api/profiles/${encodeURIComponent(key)}/clear-session`, { method: "POST" });
      const deleted = (data && data.deleted) || [];
      toast.success(deleted.length
        ? `Cleared ${deleted.length} profile dir(s). Next: click Sync and complete login in noVNC.`
        : "No on-disk data to clear (already clean).");
      refresh();
    } catch (e) { toast.error(`Clear session failed: ${e.message}`); }
  }

  async function rotateAccessUrl(key) {
    const ok = await confirmModal({
      title: `Rotate access URL for ${key}?`,
      body:  "Downstream clients (Actual, etc.) will need to be re-linked with a new SimpleFIN URL.",
      confirmLabel: "Rotate URL",
      danger: true,
    });
    if (!ok) return;
    try {
      await api(`/admin/api/profiles/${encodeURIComponent(key)}/rotate-access-url`, { method: "POST" });
      toast.success("Access URL rotated. Re-link downstream clients to the new URL.");
      refresh();
    } catch (e) { toast.error(e.message); }
  }

  async function deleteProfile(key) {
    const ok = await confirmModal({
      title: `Delete profile ${key}?`,
      body:  "All on-disk state, encrypted credentials, and run history for this profile will be erased. This cannot be undone.",
      confirmLabel: "Delete profile",
      danger: true,
    });
    if (!ok) return;
    try {
      await api(`/admin/api/profiles/${encodeURIComponent(key)}`, { method: "DELETE" });
      toast.success(`Profile ${key} deleted.`);
      refresh();
      // If we were on the profile's detail page, bounce to the list.
      if (window.location.hash.startsWith(`#/profiles/`)) navigate("#/manage");
    } catch (e) { toast.error(e.message); }
  }

  const probeBtn = document.getElementById("freentonic-refresh");
  if (probeBtn) probeBtn.addEventListener("click", probeFreentonicHealth);

  // Theme cycling — Auto → Light → Dark → Auto.
  theme.applyStoredTheme();
  const themeBtn   = document.getElementById("theme-toggle");
  const themeIcon  = document.getElementById("theme-toggle-icon");
  const themeLabel = document.getElementById("theme-toggle-label");
  const THEME_ICONS = { auto: "◐", light: "☀", dark: "☾" };
  const THEME_NAMES = { auto: "Auto", light: "Light", dark: "Dark" };
  function paintThemeButton() {
    if (!themeBtn) return;
    const cur = theme.getStored();
    if (themeIcon)  themeIcon.textContent  = THEME_ICONS[cur];
    if (themeLabel) themeLabel.textContent = THEME_NAMES[cur];
  }
  paintThemeButton();
  if (themeBtn) themeBtn.addEventListener("click", () => {
    theme.cycle();
    paintThemeButton();
  });

  async function refreshWorkflows() {
    const btn = document.getElementById("refresh-workflows-btn");
    // Default to the currently-installed ref so a re-pull is one Enter
    // away. First-time user gets "main" as the suggestion.
    const defaultRef = (workflowsMeta && workflowsMeta.ref) || "main";
    const ref = window.prompt(
      "Pull workflow YAMLs at which ref?\n\n" +
      "  - branch (e.g. main, develop)\n" +
      "  - tag    (e.g. v0.4.1)\n" +
      "  - commit SHA (full or short)\n\n" +
      "This overwrites <slug>/workflow.yml in the workflows dir; " +
      "profiles keep their workflow path, only the file contents change.",
      defaultRef
    );
    if (!ref) return;   // cancelled
    if (btn) { btn.disabled = true; btn.classList.add("spinning"); }
    try {
      const data = await api("/admin/api/workflows/refresh", {
        method: "POST",
        body:   { ref: ref.trim() }
      });
      const providers = (data && data.providers) || [];
      // Drop the cached workflow list so the next openNewProfile()
      // re-fetches; refresh the meta line in the header.
      workflowsCache = null;
      workflowsMeta  = data || null;
      renderWorkflowsMeta();
      const commitShort = (data && data.commit || "").slice(0, 7);
      toast.success(
        `Refreshed ${providers.length} provider${providers.length === 1 ? "" : "s"} ` +
        `at ${data && data.repo} @ ${data && data.ref}` +
        (commitShort ? ` (${commitShort})` : "")
      );
    } catch (e) {
      toast.error(`Refresh failed: ${e.message}`);
    } finally {
      if (btn) { btn.disabled = false; btn.classList.remove("spinning"); }
    }
  }

  const refreshWfBtn = document.getElementById("refresh-workflows-btn");
  if (refreshWfBtn) refreshWfBtn.addEventListener("click", refreshWorkflows);

  // Eagerly fetch workflows once so the meta line in the panel header
  // shows up immediately, not only after the user clicks "+ New profile".
  loadWorkflows().catch(() => { /* surfaced in alert if user opens the new-profile flow */ });

  refresh();
  setInterval(refresh, 2000);

  // Load consolidation eagerly on first paint, then again every 30 s
  // (only changes after a sync completes or an alias edit). Edits
  // call loadConsolidation() directly so the panel reflects them
  // immediately, without waiting for the slow tick.
  loadConsolidation();
  setInterval(loadConsolidation, 30000);

  loadVirtualProfile();
  setInterval(loadVirtualProfile, 30000);

  loadExportPreview();
  setInterval(loadExportPreview, 30000);

  // Route registration. The "manage" route is the existing full
  // single-page UI; dashboard and welcome are new in Phase 1. The
  // first-run nudge that may redirect to "#/welcome" lives inside
  // the welcome view itself — it subscribes to the profiles store
  // slice and acts on the first emission.
  dashboardView.mount();
  welcomeView.mount();
  profileDetailView.mount();
  consolidationOverviewView.mount();
  profileDetailView.configure({
    onSync:            triggerSync,
    onBrowse:          triggerBrowse,
    onRecord:          triggerRecord,
    onMintToken:       mintSetupToken,
    onOpenCredentials: openCredentials,
    onRebuildHistory:  rebuildHistory,
    onResetHistory:    resetHistory,
    onRotateUrl:       rotateAccessUrl,
    onClearSession:    clearSession,
    onDelete:          deleteProfile,
    onLoadRuns:        loadRunsInto,
    onSaveSchedule:    saveSchedule,
  });

  registerRoute({ id: "dashboard",     match: "#/dashboard" });
  registerRoute({ id: "welcome",       match: "#/welcome" });
  registerRoute({ id: "manage",        match: "#/manage" });
  registerRoute({ id: "consolidation", match: "#/consolidation" });
  registerRoute({
    id: "profile-detail",
    match: /^#\/profiles\/([^/]+)$/,
    onEnter: ([key]) => profileDetailView.enter(decodeURIComponent(key)),
    onLeave: () => profileDetailView.leave(),
  });
  // Default: empty hash or anything unknown lands on dashboard.
  registerRoute({ id: "dashboard", match: "*" });

  startRouter();
})();
