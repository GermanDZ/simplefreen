// DOM and clipboard helpers shared across views. Keep this module
// dependency-free so any view can import it without pulling in API
// or state.

export function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  Object.entries(attrs).forEach(([k, v]) => {
    if (k === "class") node.className = v;
    else if (k === "text") node.textContent = v;
    else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
    else if (v !== undefined && v !== null) node.setAttribute(k, v);
  });
  for (const child of children) {
    if (child == null) continue;
    if (typeof child === "string") node.appendChild(document.createTextNode(child));
    else node.appendChild(child);
  }
  return node;
}

export function truncateMiddle(str, max) {
  if (!str || str.length <= max) return str;
  const head = Math.ceil((max - 1) / 2);
  const tail = Math.floor((max - 1) / 2);
  return str.slice(0, head) + "…" + str.slice(-tail);
}

// Click-to-copy for any code-cell id. Works on acc_<hex>, txn_<hex>,
// and source_id columns. Visual feedback via a transient class so the
// operator knows the click registered.
export function copyOnClick(ev) {
  const node = ev.currentTarget;
  const text = node.title || node.textContent;
  if (!text) return;
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(() => flashCopied(node));
  } else {
    const range = document.createRange();
    range.selectNodeContents(node);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
    try { document.execCommand("copy"); flashCopied(node); }
    catch { /* nothing more to do */ }
    sel.removeAllRanges();
  }
}

export function flashCopied(node) {
  node.classList.add("copied-flash");
  setTimeout(() => node.classList.remove("copied-flash"), 600);
}

export function copyToClipboard(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).catch(() => fallbackCopy(text));
  } else {
    fallbackCopy(text);
  }
}

export function fallbackCopy(text) {
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.style.position = "fixed";
  ta.style.opacity = "0";
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand("copy"); } catch (_) {}
  ta.remove();
}
