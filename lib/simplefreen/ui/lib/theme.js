// Theme persistence — cycles through Auto (no explicit override),
// Light, and Dark. Auto follows the OS preference via the
// prefers-color-scheme media query the tokens file already
// listens to. Saved choice is keyed under simplefreen.theme.
//
// Apply the saved preference as early as possible — ideally
// before first paint — to avoid a flash of the wrong theme.
// app.js calls applyStoredTheme() at module top, before any
// rendering happens.

const STORAGE_KEY = "simplefreen.theme";
const ORDER = ["auto", "light", "dark"];

export function applyStoredTheme() {
  const v = getStored();
  apply(v);
}

export function getStored() {
  try {
    const v = window.localStorage.getItem(STORAGE_KEY);
    return ORDER.includes(v) ? v : "auto";
  } catch (_) { return "auto"; }
}

export function setStored(value) {
  if (!ORDER.includes(value)) return;
  try {
    if (value === "auto") window.localStorage.removeItem(STORAGE_KEY);
    else window.localStorage.setItem(STORAGE_KEY, value);
  } catch (_) { /* private mode etc. */ }
  apply(value);
}

export function cycle() {
  const cur = getStored();
  const next = ORDER[(ORDER.indexOf(cur) + 1) % ORDER.length];
  setStored(next);
  return next;
}

function apply(value) {
  const html = document.documentElement;
  if (value === "auto") html.removeAttribute("data-theme");
  else html.setAttribute("data-theme", value);
}
