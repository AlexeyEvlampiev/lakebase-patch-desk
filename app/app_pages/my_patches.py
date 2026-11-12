"""My patches: the user's own uploads, their state, and each line's result."""

import labels
import streamlit as st
from messages import problem_message

import db

desk: db.Desk = st.session_state.desk

patches = desk.my_patches()
if not patches:
    st.info("You have not uploaded a file yet.", title="Nothing here yet")
    st.page_link("app_pages/upload.py", label="Upload a file of fixes", icon=":material/upload_file:")
    st.stop()

st.dataframe(
    [
        {
            "Uploaded": p["submitted_at"],
            "File": p["file_name"],
            "State": [labels.patch_state(p)],
            "Lines": p["line_count"],
            "Problems": p["problem_count"],
            "Decided by": labels.person(p["decided_by"]),
            "Note": labels.text(p["decision_note"]),
            "Sent to the lakehouse": labels.when(p["exported_at"]),
        }
        for p in patches
    ],
    column_config={
        "Uploaded": labels.datetime_column("Uploaded"),
        "State": labels.state_column(),
    },
    hide_index=True,
    alt="Your change requests with their state",
)

choices = {f"{p['file_name']} ({labels.when(p['submitted_at'])})": p for p in patches}
chosen = st.selectbox("Show the lines of", list(choices), key="my_patches_chosen")
if chosen:
    lines = desk.patch_lines(choices[chosen]["patch_id"])
    st.dataframe(
        [
            {
                "Row": r["line_no"],
                "Product": r["product_code"],
                "Field": labels.field_label(r["field"]),
                "New value": r["new_value"],
                "Value at upload": labels.text(r["old_value"]),
                "Result": problem_message(r["problem"]) or "Fine",
            }
            for r in lines
        ],
        hide_index=True,
        alt="The lines of the chosen change request with their results",
    )
