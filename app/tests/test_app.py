import re
from pathlib import Path

from streamlit.testing.v1 import AppTest

ENTRY = str(Path(__file__).resolve().parents[1] / "streamlit_app.py")


def test_without_a_forwarded_token_the_app_says_so_and_connects_nowhere():
    at = AppTest.from_file(ENTRY, default_timeout=20).run()
    assert not at.exception
    assert [e.value for e in at.error] == ["Open this app from Databricks."]
    assert "desk" not in at.session_state


def test_no_streamlit_cache_in_the_app():
    # Streamlit caches are shared by every user: a cached client or
    # connection would serve one person's login to another.
    use = re.compile(r"@st\.cache_|st\.cache_(resource|data)\s*\(")
    app = Path(ENTRY).parent
    for path in app.rglob("*.py"):
        if "tests" not in path.parts:
            assert not use.search(path.read_text()), path


def test_the_session_watcher_is_on_every_page_and_leaves_only_on_a_redirect():
    import session_watch

    script = session_watch._SCRIPT
    assert 'redirect: "manual"' in script and "opaqueredirect" in script
    assert "__patchDeskSessionWatch" in script  # installed once per page load
    # On a redirect it leaves the Streamlit page (stopping its retries) for a
    # same-origin waiting page, which reopens the app later.
    assert "URL.createObjectURL(new Blob" in script and "window.location.replace" in script
    assert str(session_watch.REOPEN_AFTER_MS) in script
    assert "Reconnecting" in session_watch._WAIT_PAGE and "__TARGET__" in session_watch._WAIT_PAGE
    # st.html drops a script whose text looks like it holds HTML tags.
    body = script[script.index("<script>") + len("<script>") : script.rindex("</script>")]
    assert "<" not in body
    at = AppTest.from_file(ENTRY, default_timeout=20).run()
    assert any("__patchDeskSessionWatch" in h.value for h in at.get("html"))
