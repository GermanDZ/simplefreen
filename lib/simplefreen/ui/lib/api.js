// Single JSON fetch wrapper used by every view. A 401 means the
// session cookie expired (or was never present) — bounce to the
// login page so the operator can sign in again.

export async function api(path, opts = {}) {
  const res = await fetch(path, {
    credentials: "same-origin",
    headers: Object.assign(
      { "Content-Type": "application/json" },
      opts.headers || {}
    ),
    method: opts.method || "GET",
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  if (res.status === 401) {
    window.location.href = "/admin/login";
    return null;
  }
  if (!res.ok) {
    const txt = await res.text();
    throw new Error(`${res.status} ${txt}`);
  }
  return res.json();
}
