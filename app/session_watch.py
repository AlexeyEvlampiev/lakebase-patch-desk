"""Recover an open tab after the app restarts, instead of hanging.

Seen on the demo (2026-11-09): after a Databricks app is stopped and
started, an open tab's sign-in session is gone. Streamlit's page then keeps
calling /_stcore/health and /_stcore/host-config to reconnect, and the
Databricks Apps proxy answers each call with a redirect to sign in. A
background call cannot follow a redirect to another site, so it fails and
Streamlit retries: the page spins. Every redirect also sets a sign-in state
cookie (15 minutes each); after about 50 of them the request headers are too
big and the browser reports the site as unreachable
(ERR_HTTP2_PROTOCOL_ERROR) until the cookies expire or are cleared.

This watcher asks the same health URL every few seconds without following
redirects. A redirect means "sign in again". It then leaves the Streamlit
page at once for a small "Reconnecting" page built in the browser (a blob
URL of the same origin): leaving stops Streamlit's retries, which are what
pile up the cookies (seen: one every 1.5 to 4 seconds). That page waits
quietly until the restarted app is likely ready (it answered 25 to 60
seconds after the first redirect on the demo) and then opens the app
again; a full page load follows the sign-in redirect, so the tab recovers
by itself with a few sign-in cookies instead of dozens.
"""

import base64

import streamlit as st

CHECK_EVERY_MS = 3000
REOPEN_AFTER_MS = 75000

_WAIT_PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>Product data desk: reconnecting</title>
<style>body{font:16px sans-serif;max-width:36em;margin:15vh auto;padding:0 16px;color:#333}</style></head>
<body><h1>Reconnecting&hellip;</h1>
<p>The Product data desk was restarted. Your browser opens it again in about a minute.</p>
<p><a id="go" href="#">Open it now</a></p>
<script>
const target = __TARGET__;
document.getElementById("go").href = target;
setTimeout(() => location.replace(target), __DELAY__);
</script></body></html>"""

# Base64, because st.html drops a whole script whose text contains anything
# that looks like an HTML tag, even inside a string (seen with Streamlit 1.67).
_WAIT_PAGE_B64 = base64.b64encode(_WAIT_PAGE.encode()).decode()

_SCRIPT = f"""
<script>
(() => {{
  if (window.__patchDeskSessionWatch) return;
  window.__patchDeskSessionWatch = true;
  let leaving = false;
  setInterval(async () => {{
    if (leaving) return;
    try {{
      const r = await fetch("/_stcore/health", {{redirect: "manual", cache: "no-store", credentials: "same-origin"}});
      if (r.type === "opaqueredirect" || r.status === 401) {{
        leaving = true;
        const page = new TextDecoder().decode(Uint8Array.from(atob("{_WAIT_PAGE_B64}"), (c) => c.charCodeAt(0)))
          .replace("__TARGET__", JSON.stringify(window.location.href))
          .replace("__DELAY__", "{REOPEN_AFTER_MS}");
        window.location.replace(URL.createObjectURL(new Blob([page], {{type: "text/html"}})));
      }}
    }} catch (e) {{
      // Network down or app not reachable yet: keep waiting.
    }}
  }}, {CHECK_EVERY_MS});
}})();
</script>
"""


def watch_session() -> None:
    """Install the watcher once per page load. The script is fixed text, never user input."""
    st.html(_SCRIPT, unsafe_allow_javascript=True, width="content")
