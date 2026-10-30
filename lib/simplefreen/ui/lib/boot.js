// Synchronous boot script — applies the saved theme before the
// body is parsed so the first paint matches the operator's
// preference, and (on the login page only) flips on the inline
// error banner when the server redirected back with ?e=1.
//
// Loaded via <script src="…"></script> (NOT type="module") so it
// runs at parse time, before any deferred module would. Lives in
// its own file because the simplefreen CSP forbids inline scripts.
(function () {
  try {
    var t = window.localStorage.getItem("simplefreen.theme");
    if (t === "light" || t === "dark") {
      document.documentElement.setAttribute("data-theme", t);
    }
  } catch (_) { /* private mode etc. */ }

  // Login-page only: surface "Incorrect password" when redirected
  // back with ?e=1. No-op on every other page (no #login-error).
  function showLoginError() {
    if (!/[?&]e=1\b/.test(window.location.search)) return;
    var err = document.getElementById("login-error");
    if (err) err.hidden = false;
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", showLoginError);
  } else {
    showLoginError();
  }
})();
