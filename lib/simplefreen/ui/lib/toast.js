// Transient banner notifications. Replaces ad-hoc alert() calls
// with non-blocking UI. Stack up to 4 visible; older ones drop
// off the top. Auto-dismiss after a per-variant timeout, except
// errors which stay until the operator clicks "x" (so a failed
// destructive action doesn't vanish before they see it).

import { el } from "./dom.js";

const VARIANT_TIMEOUTS = {
  info:    3500,
  success: 3500,
  error:     0,  // sticky
};

let containerEl = null;

function container() {
  if (containerEl) return containerEl;
  containerEl = el("div", { id: "toast-stack", role: "status", "aria-live": "polite" });
  document.body.appendChild(containerEl);
  return containerEl;
}

function show(message, variant) {
  const node = el("div", { class: `toast toast-${variant}` },
    el("span", { class: "toast-msg" }, message),
    el("button", {
      type: "button",
      class: "toast-close",
      "aria-label": "Dismiss",
      onclick: () => dismiss(node),
    }, "×"),
  );
  container().appendChild(node);
  while (container().childElementCount > 4) {
    container().firstElementChild.remove();
  }
  const ms = VARIANT_TIMEOUTS[variant] ?? VARIANT_TIMEOUTS.info;
  if (ms > 0) setTimeout(() => dismiss(node), ms);
  return node;
}

function dismiss(node) {
  if (!node || !node.isConnected) return;
  node.classList.add("toast-leaving");
  setTimeout(() => node.remove(), 180);
}

export function toast(message, variant = "info") {
  return show(message, variant);
}

export const info    = (msg) => show(msg, "info");
export const success = (msg) => show(msg, "success");
export const error   = (msg) => show(msg, "error");
