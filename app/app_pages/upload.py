"""Upload page: send a file of fixes to the database and show each line's result."""

import excel
import labels
import streamlit as st
from messages import problem_message

import db

desk: db.Desk = st.session_state.desk

st.markdown(
    "Upload an Excel file (.xlsx) with the columns "
    + ", ".join(f"`{c}`" for c in excel.COLUMNS)
    + ". Each row changes one field of one product. The database checks every line at once."
)
st.download_button(
    "Download a sample file",
    data=excel.sample_file(),
    file_name="product-fixes.xlsx",
    mime="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    icon=":material/download:",
)

with st.form("upload", clear_on_submit=True):
    uploaded = st.file_uploader("Excel file with fixes", type=["xlsx"], max_upload_size=5)
    submitted = st.form_submit_button("Check and submit", icon=":material/send:", type="primary")

if submitted:
    if uploaded is None:
        st.warning("Choose a file first.")
    else:
        try:
            lines = excel.read_lines(uploaded.getvalue())
        except excel.FileProblem as e:
            st.error(str(e), title="Cannot read the file")
        else:
            try:
                patch = desk.submit_patch(uploaded.name, lines)
            except db.SignInExpired:
                st.warning("Your sign-in has expired. Reload the page.", title="Signed out")
                st.stop()
            except db.ConnectionLost:
                st.error(
                    "The connection to the database dropped during the upload. Reload the page "
                    "and check whether the file was stored before you upload it again.",
                    title="Connection lost",
                )
                st.stop()
            if patch is None:
                st.error("The database did not accept the file.", title="Not stored")
            else:
                st.session_state.upload_patch = patch

patch = st.session_state.get("upload_patch")
if patch:
    rows = desk.patch_lines(patch["patch_id"])
    problems = sum(1 for r in rows if r["problem"])
    if patch["state"] == "pending":
        st.success(f"All {len(rows)} lines are fine. The change request now waits for an approver.", title="Submitted")
    else:
        st.warning(
            f"{problems} of {len(rows)} lines have a problem. Fix the file and upload it again.",
            title="Not submitted for approval",
        )
    st.dataframe(
        [
            {
                "Row": r["line_no"],
                "Product": r["product_code"],
                "Field": labels.field_label(r["field"]),
                "New value": r["new_value"],
                "Current value": labels.text(r["old_value"]),
                "Result": problem_message(r["problem"]) or "Fine",
            }
            for r in rows
        ],
        hide_index=True,
        alt="Each line of the uploaded file with its result",
    )
