"""History: every step on the patches the user may see, newest first."""

import labels
import streamlit as st

import db

desk: db.Desk = st.session_state.desk

events = desk.history()
if not events:
    st.info("Nothing has happened yet. Uploads, decisions and exports show up here.", title="No history yet")
    st.page_link("app_pages/upload.py", label="Upload a file of fixes", icon=":material/upload_file:")
    st.stop()

rows = [
    {
        "When": e["at"],
        "File": e["file_name"],
        "What": labels.EVENTS.get(e["event"], e["event"]),
        "Who": [labels.EXPORT_JOB if e["event"] == "exported" else labels.person(e["actor"])],
        "Note": labels.text(e["note"]),
    }
    for e in events
]
st.dataframe(
    rows,
    column_config={
        "When": labels.datetime_column("When"),
        "Who": labels.who_column(r["Who"][0] for r in rows),
    },
    hide_index=True,
    alt="Events on the change requests you may see, newest first",
)
