// Promise-returning confirm modal. Replaces window.confirm() so
// destructive actions get a properly styled dialog with title +
// body + a danger button when appropriate, instead of a bare OS
// prompt.
//
// Usage:
//   const ok = await confirm({
//     title: "Delete profile ing_personal?",
//     body:  "This cannot be undone.",
//     confirmLabel: "Delete",
//     danger: true,
//   });
//   if (!ok) return;

import { el } from "./dom.js";

export function confirm(opts) {
  const { title, body, confirmLabel = "Confirm", cancelLabel = "Cancel", danger = false } = opts || {};

  return new Promise((resolve) => {
    let closed = false;
    const cleanup = (value) => {
      if (closed) return;
      closed = true;
      document.removeEventListener("keydown", onKey);
      backdrop.remove();
      resolve(value);
    };

    const onKey = (e) => {
      if (e.key === "Escape") cleanup(false);
      if (e.key === "Enter") cleanup(true);
    };

    const confirmBtn = el("button", {
      type: "button",
      class: danger ? "modal-confirm modal-danger" : "modal-confirm primary",
      onclick: () => cleanup(true),
    }, confirmLabel);

    const dialog = el("div", { class: "modal-dialog", role: "dialog", "aria-modal": "true", "aria-labelledby": "modal-title" },
      el("h2", { id: "modal-title", class: "modal-title" }, title),
      bodyNode(body),
      el("div", { class: "modal-actions" },
        el("button", {
          type: "button",
          class: "modal-cancel",
          onclick: () => cleanup(false),
        }, cancelLabel),
        confirmBtn,
      ),
    );

    const backdrop = el("div", {
      class: "modal-backdrop",
      onclick: (e) => { if (e.target === backdrop) cleanup(false); },
    }, dialog);

    document.body.appendChild(backdrop);
    document.addEventListener("keydown", onKey);
    setTimeout(() => confirmBtn.focus(), 0);
  });
}

function bodyNode(body) {
  if (body == null) return el("div", { class: "modal-body" });
  if (typeof body === "string") return el("p", { class: "modal-body" }, body);
  return el("div", { class: "modal-body" }, body);
}
