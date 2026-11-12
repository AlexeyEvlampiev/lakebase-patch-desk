"""Business words for the codes the database returns, shared by every page.

States and events come from the CHECK constraints in
db/core/patch-structure.sql, fields from core.fn_patch_line_problems in
db/core/patch.sql. A test fails when the SQL gains a code that has
no word here.
"""

from __future__ import annotations

import datetime
from collections.abc import Iterable, Mapping
from typing import Any

import streamlit as st

STATES: dict[str, str] = {
    "invalid": "Has problems",
    "pending": "Waiting for approval",
    "approved": "Approved",
    "rejected": "Rejected",
}
EXPORTED = "Sent to the lakehouse"

# One badge colour per state, in the order the states are listed on screen.
STATE_COLORS: dict[str, str] = {
    STATES["invalid"]: "red",
    STATES["pending"]: "orange",
    STATES["approved"]: "blue",
    STATES["rejected"]: "gray",
    EXPORTED: "green",
}

EVENTS: dict[str, str] = {
    "submitted": "Submitted",
    "approved": "Approved",
    "rejected": "Rejected",
    "exported": EXPORTED,
}

FIELDS: dict[str, str] = {
    "name": "Name",
    "category": "Category",
    "unit_price": "Unit price",
    "active": "Active",
}

EXPORT_JOB = "Lakehouse export"  # who the screen names for the export job
PERSON_COLOR = "gray"

DATETIME_FORMAT = "%Y-%m-%d %H:%M"  # for text; DATETIME_COLUMN_FORMAT for tables
DATETIME_COLUMN_FORMAT = "YYYY-MM-DD HH:mm"


def patch_state(patch: Mapping[str, Any]) -> str:
    """The state a person sees: an exported patch counts as sent to the lakehouse."""
    if patch.get("exported_at"):
        return EXPORTED
    return STATES.get(patch["state"], patch["state"])


def field_label(code: str | None) -> str:
    """The field's name on screen; a field the database does not know stays as typed."""
    if code is None:
        return ""
    return FIELDS.get(code, code)


def person(email: str | None) -> str:
    """A person as the screen shows them: the part of the email before the @.

    The database and logs keep the full email; the screen shows no domain.
    """
    if email is None:
        return ""
    return email.split("@", 1)[0]


def text(value: str | None) -> str:
    """A table cell: blank when the database has no value."""
    return "" if value is None else value


def when(at: datetime.datetime | None) -> str:
    """A date and time in the one format the app uses for text."""
    return "" if at is None else f"{at:{DATETIME_FORMAT}}"


def state_column(label: str = "State") -> Any:
    """A read-only column that shows a patch state as a coloured badge.

    Cells hold a one-item list, e.g. ["Approved"].
    """
    return st.column_config.MultiselectColumn(label, options=list(STATE_COLORS), color=list(STATE_COLORS.values()))


def who_column(names: Iterable[str], label: str = "Who") -> Any:
    """A read-only column that shows who did something as a grey badge.

    Cells hold a one-item list, e.g. ["approver"].
    """
    options = sorted(set(names))
    return st.column_config.MultiselectColumn(label, options=options, color=[PERSON_COLOR for _ in options])


def datetime_column(label: str) -> Any:
    """A date and time column in the app's one format."""
    return st.column_config.DatetimeColumn(label, format=DATETIME_COLUMN_FORMAT)
