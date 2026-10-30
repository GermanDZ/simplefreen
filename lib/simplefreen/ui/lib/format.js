// Pure formatters — no DOM, no fetch. Safe to import from anywhere.

export function formatInterval(seconds) {
  if (seconds < 3600) return `${Math.round(seconds / 60)}m`;
  if (seconds < 86400) return `${(seconds / 3600).toFixed(1).replace(/\.0$/, "")}h`;
  return `${Math.round(seconds / 86400)}d`;
}

export function formatBytes(n) {
  if (n == null) return "?";
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

export function lookbackLabel(p) {
  const mode = p.lookback_mode || "incremental";
  if (mode === "incremental") {
    const overlap = p.lookback_overlap_days || 10;
    const max = p.max_lookback_days || 365;
    return `lookback incremental (+${overlap}d, max ${max})`;
  }
  return `lookback fixed ${p.lookback_days}d`;
}

export function historyLabel(p) {
  const h = p.history;
  if (!h || !h.txn_count) return "history: empty";
  const parts = [`${h.txn_count.toLocaleString()} txns`];
  if (h.last_tx_date) parts.push(`last ${h.last_tx_date}`);
  if (h.file_size_bytes != null) parts.push(formatBytes(h.file_size_bytes));
  return `history: ${parts.join(" · ")}`;
}

export function formatWindow(from, to) {
  if (!from && !to) return "all dates";
  if (from && !to)  return `${from} → now`;
  if (!from && to)  return `← ${to}`;
  return `${from} → ${to}`;
}

export function confTier(c) {
  if (c >= 0.9) return "hi";
  if (c >= 0.7) return "med";
  return "lo";
}

export function isoPrevDay(iso) {
  const d = new Date(iso);
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
}

export function quoteIfNeeded(value) {
  const s = String(value);
  if (s === "" || /[:#\[\]{},&*!|>'"%@`\n]/.test(s) || /^\s|\s$/.test(s)) {
    return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  }
  return s;
}

// Human-readable elapsed duration. Accepts milliseconds.
// "850ms" / "12s" / "1m 24s" / "1h 5m". Bounded — anything past a
// day falls back to "Xh" since long runs aren't a happy path.
export function formatDuration(ms) {
  if (ms == null || !Number.isFinite(ms)) return "?";
  if (ms < 1000) return `${ms}ms`;
  const sec = Math.floor(ms / 1000);
  if (sec < 60) return `${sec}s`;
  const min = Math.floor(sec / 60);
  const rem = sec % 60;
  if (min < 60) return rem ? `${min}m ${rem}s` : `${min}m`;
  const hr = Math.floor(min / 60);
  const mrem = min % 60;
  return mrem ? `${hr}h ${mrem}m` : `${hr}h`;
}

// Human-readable "time since" for ISO timestamps and millisecond
// epoch ints. Returns "just now" / "5m ago" / "2h ago" / "3d ago"
// / a formatted date past a week. Null/undefined ⇒ "never".
export function timeAgo(input) {
  if (input == null || input === "") return "never";
  const ts = typeof input === "number" ? input : Date.parse(input);
  if (Number.isNaN(ts)) return "never";
  const diffSec = Math.floor((Date.now() - ts) / 1000);
  if (diffSec < 5) return "just now";
  if (diffSec < 60) return `${diffSec}s ago`;
  if (diffSec < 3600) return `${Math.floor(diffSec / 60)}m ago`;
  if (diffSec < 86400) return `${Math.floor(diffSec / 3600)}h ago`;
  if (diffSec < 7 * 86400) return `${Math.floor(diffSec / 86400)}d ago`;
  const d = new Date(ts);
  return d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

export function urlPathHint(url) {
  try {
    const u = new URL(url);
    return u.pathname && u.pathname !== "/" ? u.pathname : url;
  } catch (_) {
    return url;
  }
}
