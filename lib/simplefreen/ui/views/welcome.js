// Welcome — shown automatically on first run (zero profiles AND
// the dismissed flag not set in localStorage). Once dismissed,
// stays accessible at #/welcome but never auto-redirects again.
//
// Copy is intentionally short. The operator guide in docs/ is the
// canonical reference; this view is the in-app orientation card.

import { el } from "../lib/dom.js";
import { subscribe } from "../lib/store.js";
import { navigate } from "../lib/router.js";

const DISMISSED_KEY = "simplefreen.welcome.dismissed";

let mounted = false;
let firstRunChecked = false;

export function mount() {
  if (mounted) return;
  mounted = true;
  render();

  // First-run auto-redirect: the very first time we see a profile
  // list (even if it's empty), if there are zero profiles AND the
  // operator hasn't dismissed, send them to #/welcome. We only
  // check once — subsequent state changes don't pull them back in.
  subscribe("profiles", (profiles) => {
    if (firstRunChecked || profiles === undefined) return;
    firstRunChecked = true;
    if (!profiles.length && !isDismissed() && !window.location.hash.startsWith("#/welcome")) {
      navigate("#/welcome");
    }
  });
}

function render() {
  const root = document.getElementById("welcome-body");
  if (!root) return;
  root.replaceChildren(
    el("section", { class: "panel welcome-hero" },
      el("h1", { class: "welcome-title" }, "Welcome to simplefreen"),
      el("p", { class: "welcome-lead" },
        "A SimpleFIN bridge for Actual Budget and other SimpleFIN-compatible clients. ",
        "Simplefreen manages encrypted bank credentials, schedules syncs, and serves a ",
        "SimpleFIN URL per profile (and one consolidated URL across all of them). ",
        "It delegates the actual scraping to a separate ",
        el("code", {}, "freentonic"),
        " server."
      ),
    ),
    el("section", { class: "panel" },
      el("h2", {}, "How it works"),
      el("ol", { class: "welcome-steps" },
        el("li", {},
          el("strong", {}, "Create a profile."),
          " Pick a workflow from the providers repo (e.g. ING, BBVA), give it a key, and store the bank credentials. Secrets are encrypted at rest with AES-256-GCM."
        ),
        el("li", {},
          el("strong", {}, "Sync."),
          " The first sync opens Chrome inside the freentonic container; you watch it through the inline VNC viewer and complete any 2FA. Subsequent syncs reuse the warmed session."
        ),
        el("li", {},
          el("strong", {}, "Link to Actual."),
          " Mint a one-shot setup token and paste it into Actual Budget's SimpleFIN setup field. From then on, Actual fetches accounts and transactions over the SimpleFIN wire protocol."
        ),
      ),
    ),
    el("section", { class: "panel welcome-cta" },
      el("h2", {}, "Get started"),
      el("p", { class: "sub" },
        "Head to ", el("strong", {}, "Manage"),
        " to create your first profile, or open the dashboard for an at-a-glance view."
      ),
      el("div", { class: "row" },
        el("a", { class: "button-link", href: "#/manage" }, "Open Manage"),
        el("a", { class: "button-link welcome-secondary", href: "#/dashboard" }, "Go to Dashboard"),
        el("button", {
          type: "button",
          class: "welcome-dismiss",
          onclick: dismissAndGoToManage,
          title: "Don't show this on next visit",
        }, "Don't show again"),
      ),
    ),
    el("p", { class: "sub welcome-footer" },
      "Need more detail? See the operator guide and architecture notes in the ",
      el("code", {}, "docs/"),
      " directory of the simplefreen repo."
    ),
  );
}

function dismissAndGoToManage() {
  try { window.localStorage.setItem(DISMISSED_KEY, "1"); }
  catch (_) { /* private mode etc. — fine, just lose the preference */ }
  navigate("#/manage");
}

function isDismissed() {
  try { return window.localStorage.getItem(DISMISSED_KEY) === "1"; }
  catch (_) { return false; }
}
