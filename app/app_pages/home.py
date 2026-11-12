"""Home: what needs the signed-in person's attention, with counts.

Counts come from the data the other pages already read (my_patches,
pending_patches); row-level security in Postgres decides what is counted.
"""

from collections import Counter

import labels
import streamlit as st

import db

desk: db.Desk = st.session_state.desk

UPLOAD = "app_pages/upload.py"
MY_PATCHES = "app_pages/my_patches.py"
REVIEW = "app_pages/review.py"


def tile(label: str, value: int, page: str, link: str, icon: str) -> None:
    """A metric card with a link to the page where the person acts on it."""
    with st.container(border=True):
        st.metric(label, value)
        st.page_link(page, label=link, icon=icon)


st.markdown(
    "Fix product data with an Excel file. The database checks every line at once, "
    "an approver signs off, and approved fixes go to the lakehouse."
)
st.page_link(UPLOAD, label="Upload a file of fixes", icon=":material/upload_file:")

mine = Counter(labels.patch_state(p) for p in desk.my_patches())
attention = mine[labels.STATES["invalid"]] + mine[labels.STATES["rejected"]]

approver = desk.is_approver()
if approver:
    to_review = [p for p in desk.pending_patches() if not p["own"]]
    attention += len(to_review)
    st.subheader("Waiting for your decision")
    with st.grid(2, gap="medium"):
        tile("Requests to review", len(to_review), REVIEW, "Review them", ":material/fact_check:")

# An approver who never uploaded anything sees no row of zeros.
if mine or not approver:
    st.subheader("Your requests")
    with st.grid(4, gap="medium"):
        tile(
            labels.STATES["pending"],
            mine[labels.STATES["pending"]],
            MY_PATCHES,
            "See them",
            ":material/hourglass_top:",
        )
        tile(
            labels.STATES["rejected"],
            mine[labels.STATES["rejected"]],
            MY_PATCHES,
            "Read the notes",
            ":material/undo:",
        )
        tile(
            labels.STATES["invalid"],
            mine[labels.STATES["invalid"]],
            UPLOAD,
            "Fix and upload again",
            ":material/error:",
        )
        tile(labels.EXPORTED, mine[labels.EXPORTED], MY_PATCHES, "See them", ":material/database:")

if attention == 0:
    st.success("Nothing needs your attention.", title="All clear")
