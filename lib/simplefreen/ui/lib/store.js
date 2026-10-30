// Tiny pub/sub state store. One source of truth for "what does the
// server say is happening right now" — the 2s status poll and the
// slower consolidation / virtual-profile / export-preview /
// workflows / freentonic-health loaders all write into it.
//
// Views currently still render imperatively from the loaders;
// subscribers will replace those direct calls in later phases. The
// store itself has no opinion about render strategy — it's just a
// keyed cache with change notifications.

const state = Object.create(null);
const subs  = new Map(); // key -> Set<fn(value)>

export function getState(key) {
  return key === undefined ? Object.assign({}, state) : state[key];
}

export function setState(key, value) {
  state[key] = value;
  const set = subs.get(key);
  if (!set) return;
  for (const fn of set) {
    try { fn(value); }
    catch (e) { console.error(`[store] subscriber for "${key}" threw:`, e); }
  }
}

// Subscribe to a single key. The callback fires immediately with
// the current value (which may be undefined) and again on every
// setState for that key. Returns an unsubscribe function.
export function subscribe(key, fn) {
  let set = subs.get(key);
  if (!set) {
    set = new Set();
    subs.set(key, set);
  }
  set.add(fn);
  try { fn(state[key]); }
  catch (e) { console.error(`[store] initial fire for "${key}" threw:`, e); }
  return () => set.delete(fn);
}
