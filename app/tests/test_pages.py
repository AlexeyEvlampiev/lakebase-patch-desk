import re
from pathlib import Path

import numpy

from fake_desk import FakeDesk
from streamlit.testing.v1 import AppTest

ENTRY = str(Path(__file__).resolve().parents[1] / "streamlit_app.py")


def app(desk):
    at = AppTest.from_file(ENTRY, default_timeout=20)
    at.session_state["desk"] = desk
    return at.run()


def page_titles(at):
    return [t.value for t in at.title]


def test_review_is_reachable_for_an_approver():
    at = app(FakeDesk(approver=True))
    assert not at.exception
    at.switch_page("app_pages/review.py").run()
    assert not at.exception
    assert page_titles(at) == ["Review"]


def test_review_is_not_in_the_navigation_for_an_uploader():
    at = app(FakeDesk(approver=False))
    assert not at.exception
    try:
        at.switch_page("app_pages/review.py")
    except ValueError:
        return  # not a registered page
    raise AssertionError("an uploader reached the Review page")


def review(desk):
    at = app(desk)
    at.switch_page("app_pages/review.py").run()
    assert not at.exception
    return at


def buttons(at, label):
    return [b for b in at.button if b.label == label]


def test_own_patch_cannot_be_approved_and_says_why():
    at = review(FakeDesk())
    own_approve, other_approve = buttons(at, "Approve")
    own_reject, other_reject = buttons(at, "Reject")
    assert own_approve.disabled and own_reject.disabled
    assert not other_approve.disabled and not other_reject.disabled
    assert "Someone else must decide on your own change request." in [w.value for w in at.warning]


def test_approving_another_patch_sends_the_note():
    desk = FakeDesk()
    at = review(desk)
    at.text_input(key="note_p-other").set_value("looks right")
    buttons(at, "Approve")[1].click().run()
    assert not at.exception
    assert desk.calls == [("approve", "p-other", "looks right")]
    assert [s.value for s in at.success] == ["theirs.xlsx approved."]


def test_a_refusal_from_the_database_is_shown_plainly():
    desk = FakeDesk(refusal="core.patch.stale")
    at = review(desk)
    buttons(at, "Reject")[1].click().run()
    assert not at.exception
    assert desk.calls == [("reject", "p-other", "")]
    assert "A product changed after the upload. Upload the file again." in [e.value for e in at.error]


def test_my_patches_and_history_render():
    for page in ("app_pages/my_patches.py", "app_pages/history.py", "app_pages/upload.py"):
        at = app(FakeDesk())
        at.switch_page(page).run()
        assert not at.exception, page


class RefusingDesk:
    def connect(self):
        import db

        raise db.DatabricksRefused("This API is disabled for users without the workspace-access entitlement.")


def test_a_databricks_refusal_is_shown_with_its_reason(monkeypatch):
    import db

    monkeypatch.setattr(db, "Desk", lambda *a, **k: RefusingDesk())
    monkeypatch.setattr(db, "user_token", lambda headers: "user-token")
    at = AppTest.from_file(ENTRY, default_timeout=20).run()
    assert not at.exception
    assert "workspace-access entitlement" in at.warning[0].value


def test_review_shows_no_agent_controls():
    at = review(FakeDesk())
    assert not at.toggle
    assert not [m.value for m in at.markdown if "badge[" in m.value]
    assert len(buttons(at, "Approve")) == 2


def test_history_names_people_and_the_export_job():
    at = app(FakeDesk())
    at.switch_page("app_pages/history.py").run()
    assert not at.exception
    who = [list(w) for w in at.dataframe[0].value["Who"]]
    assert who == [["approver"], ["Lakehouse export"]]


class StalledDesk:
    def connect(self):
        import db

        raise db.Unavailable("TimeoutError")


def test_an_unreachable_database_shows_a_message_and_a_retry_button(monkeypatch):
    import db

    monkeypatch.setattr(db, "Desk", lambda *a, **k: StalledDesk())
    monkeypatch.setattr(db, "user_token", lambda headers: "user-token")
    at = AppTest.from_file(ENTRY, default_timeout=20).run()
    assert not at.exception
    assert "did not answer in time" in at.warning[0].value
    assert [b.label for b in at.button] == ["Try again"]
    assert "desk" not in at.session_state


CODES = {"invalid", "pending", "approved", "rejected", "unit_price", "name", "category", "active"}


def cells(table):
    """Every cell of a rendered dataframe, one-item lists unpacked."""
    out = set()
    for column in table.value.columns:
        for v in table.value[column]:
            out.update(v.tolist() if isinstance(v, numpy.ndarray) else [v])
    return {str(v) for v in out}


def test_my_patches_shows_states_and_fields_in_words():
    at = app(FakeDesk())
    at.switch_page("app_pages/my_patches.py").run()
    assert not at.exception
    patches, lines = at.dataframe
    assert [list(s) for s in patches.value["State"]] == [["Waiting for approval"], ["Sent to the lakehouse"]]
    assert list(lines.value["Field"]) == ["Unit price"]
    assert not (cells(patches) | cells(lines)) & CODES


def test_review_shows_fields_in_words():
    at = review(FakeDesk())
    assert all(list(t.value["Field"]) == ["Unit price"] for t in at.dataframe)


def test_history_shows_events_in_words():
    at = app(FakeDesk())
    at.switch_page("app_pages/history.py").run()
    assert not at.exception
    assert list(at.dataframe[0].value["What"]) == ["Submitted", "Sent to the lakehouse"]
    assert not cells(at.dataframe[0]) & CODES


class EmptyDesk(FakeDesk):
    def my_patches(self):
        return []

    def history(self):
        return []


def test_empty_pages_point_to_upload():
    for page in ("app_pages/my_patches.py", "app_pages/history.py"):
        at = app(EmptyDesk())
        at.switch_page(page).run()
        assert not at.exception, page
        assert at.info, page


def metrics(at):
    return {m.label: m.value for m in at.metric}


def test_the_app_opens_on_home():
    at = app(FakeDesk(approver=False))
    assert page_titles(at) == ["Home"]


def test_home_counts_for_an_approver():
    at = app(FakeDesk(approver=True))
    assert not at.exception
    assert metrics(at) == {
        "Requests to review": "1",  # not the approver's own
        "Waiting for approval": "1",
        "Rejected": "0",
        "Has problems": "0",
        "Sent to the lakehouse": "1",
    }
    assert not at.success  # a patch waits for this approver


def test_home_shows_no_review_tiles_to_an_uploader():
    at = app(FakeDesk(approver=False))
    assert not at.exception
    assert "Requests to review" not in metrics(at)
    assert [s.value for s in at.success] == ["Nothing needs your attention."]


def test_every_home_tile_links_to_where_the_work_is_done():
    at = app(FakeDesk(approver=True))
    links = {(link.proto.label, link.proto.page) for link in at.get("page_link")}
    assert links == {
        ("Upload a file of fixes", "upload"),
        ("Review them", "review"),
        ("See them", "my_patches"),
        ("Read the notes", "my_patches"),
        ("Fix and upload again", "upload"),
    }


def test_home_reads_no_new_data():
    desk = FakeDesk()
    desk.history = None  # Home must not need anything beyond my_patches and pending_patches
    at = app(desk)
    assert not at.exception


PAGES = (
    "app_pages/home.py",
    "app_pages/upload.py",
    "app_pages/my_patches.py",
    "app_pages/review.py",
    "app_pages/history.py",
)


def on_screen_text(at):
    """Every visible string AppTest can see on the page."""
    texts = []
    for kind in ("title", "subheader", "caption", "markdown", "info", "success", "warning", "error", "metric"):
        for element in at.get(kind):
            texts.append(str(getattr(element, "label", "") or ""))
            texts.append(str(getattr(element, "value", "") or ""))
    for link in at.get("page_link"):
        texts.append(link.proto.label)
    for button in at.button:
        texts.append(button.label)
    return texts


def test_no_page_says_patch():
    for page in PAGES:
        at = app(FakeDesk(approver=True))
        at.switch_page(page).run()
        assert not at.exception, page
        said = [t for t in on_screen_text(at) if "patch" in t.lower()]
        assert said == [], page


def test_no_page_title_or_help_says_patch():
    # AppTest does not expose the navigation, so read the st.Page arguments.
    source = Path(ENTRY).read_text()
    shown = re.findall(r'(?:title|help|page_title)=f?"([^"]*)"', source)
    assert "My requests" in shown
    assert [t for t in shown if "patch" in t.lower()] == []


def test_the_app_is_the_product_data_desk():
    at = app(FakeDesk())
    assert any(c.value.startswith("Product data desk") for c in at.caption)


def test_no_page_shows_an_email():
    for page in PAGES:
        at = app(FakeDesk(approver=True))
        at.switch_page(page).run()
        assert not at.exception, page
        shown = on_screen_text(at) + [str(c) for t in at.dataframe for c in cells(t)]
        assert [t for t in shown if "@example.com" in t] == [], page


def test_people_are_shown_by_the_part_before_the_at():
    at = app(FakeDesk())
    assert any(c.value == "Product data desk, signed in as approver" for c in at.caption)


class ReviewOnlyDesk(FakeDesk):
    def my_patches(self):
        return []


def test_an_approver_without_requests_sees_no_row_of_zeros():
    at = app(ReviewOnlyDesk(approver=True))
    assert not at.exception
    assert [s.value for s in at.subheader] == ["Waiting for your decision"]


def test_an_uploader_always_sees_their_requests():
    at = app(ReviewOnlyDesk(approver=False))
    assert [s.value for s in at.subheader] == ["Your requests"]


def test_no_table_cell_says_none():
    for page in PAGES:
        at = app(FakeDesk(approver=True))
        at.switch_page(page).run()
        assert not at.exception, page
        for table in at.dataframe:
            for column in ("Note", "Value at upload", "Current value", "Sent to the lakehouse"):
                if column in table.value.columns:
                    assert not table.value[column].isna().any(), (page, column)  # None and NaT both show "None"


def test_no_page_shows_an_identity_id():
    for page in PAGES:
        at = app(FakeDesk(approver=True))
        at.switch_page(page).run()
        assert not at.exception, page
        shown = on_screen_text(at) + [str(c) for t in at.dataframe for c in cells(t)]
        assert [t for t in shown if re.search(r"[0-9a-f]{8}-[0-9a-f]{4}-", t)] == [], page


def test_one_line_is_not_plural():
    at = review(FakeDesk())
    assert any(c.value.endswith("1 line") for c in at.caption)
