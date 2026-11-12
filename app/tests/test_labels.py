import datetime
import re
from pathlib import Path

import labels

CORE = Path(__file__).resolve().parents[2] / "db" / "core"
TABLES = (CORE / "patch-structure.sql").read_text()
FUNCTIONS = (CORE / "patch.sql").read_text()


def check_values(constraint: str) -> set[str]:
    """The values a CHECK (x IN (...)) constraint allows."""
    match = re.search(constraint + r"\s+CHECK\s*\(\w+\s+IN\s*\(([^)]*)\)\)", TABLES)
    assert match, constraint
    return set(re.findall(r"'([a-z_]+)'", match.group(1)))


def test_every_patch_state_has_a_word():
    assert labels.STATES.keys() == check_values("patch_state_check")


def test_every_event_has_a_word():
    assert labels.EVENTS.keys() == check_values("patch_event_event_check")


def test_every_field_has_a_word():
    match = re.search(r"c\.field NOT IN \(([^)]*)\)", FUNCTIONS)
    assert match
    assert labels.FIELDS.keys() == set(re.findall(r"'([a-z_]+)'", match.group(1)))


def test_every_state_word_has_a_colour():
    assert set(labels.STATE_COLORS) == {*labels.STATES.values(), labels.EXPORTED}


def test_an_exported_patch_is_sent_to_the_lakehouse():
    at = datetime.datetime(2026, 11, 10, 9, 30, 15, tzinfo=datetime.UTC)
    assert labels.patch_state({"state": "approved", "exported_at": at}) == "Sent to the lakehouse"
    assert labels.patch_state({"state": "approved", "exported_at": None}) == "Approved"


def test_unknown_field_stays_as_typed_and_dates_have_no_seconds():
    assert labels.field_label("colour") == "colour"
    assert labels.field_label(None) == ""
    assert labels.when(datetime.datetime(2026, 11, 10, 9, 30, 15, tzinfo=datetime.UTC)) == "2026-11-10 09:30"
    assert labels.when(None) == ""


def test_a_person_is_shown_without_the_domain():
    assert labels.person("uploader@example.com") == "uploader"
    assert labels.person("no-at-sign") == "no-at-sign"
    assert labels.person(None) == ""


def test_an_empty_cell_is_blank():
    assert labels.text(None) == ""
    assert labels.text("2.99") == "2.99"
