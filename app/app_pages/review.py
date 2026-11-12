"""Review: approvers decide on pending patches. The database checks every
decision again (fn_approve_patch, fn_reject_patch); this page only keeps the
screen clean."""

import labels
import streamlit as st
from messages import problem_message

import db

desk: db.Desk = st.session_state.desk

if not desk.is_approver():
    st.info("Only approvers decide on change requests.")
    st.stop()

done = st.session_state.pop("review_done", None)
if done:
    st.success(done)

pending = desk.pending_patches()
if not pending:
    st.info("No change request is waiting for a decision.")
    st.stop()

for p in pending:
    key = str(p["patch_id"])
    with st.container(border=True):
        st.subheader(p["file_name"])
        who = labels.person(p["submitted_by"])
        st.caption(
            f"Uploaded by {who} on {labels.when(p['submitted_at'])}, {p['line_count']} line{'' if p['line_count'] == 1 else 's'}"
        )
        lines = desk.patch_lines(p["patch_id"])
        st.dataframe(
            [
                {
                    "Row": r["line_no"],
                    "Product": r["product_code"],
                    "Field": labels.field_label(r["field"]),
                    "Value at upload": labels.text(r["old_value"]),
                    "New value": r["new_value"],
                    "Reason": r["reason"],
                }
                for r in lines
            ],
            hide_index=True,
            alt=f"The lines of {p['file_name']}",
        )
        if p["approve_problem"]:
            st.warning(problem_message(p["approve_problem"]))
        with st.form(f"decide_{key}"):
            note = st.text_input("Note", key=f"note_{key}", placeholder="Optional, shown in the history")
            approve, reject = st.columns(2)
            approved = approve.form_submit_button(
                "Approve", icon=":material/check:", type="primary", disabled=bool(p["approve_problem"]), width="stretch"
            )
            rejected = reject.form_submit_button(
                "Reject", icon=":material/close:", disabled=bool(p["own"]), width="stretch"
            )
        if approved or rejected:
            try:
                refusal = desk.approve(p["patch_id"], note) if approved else desk.reject(p["patch_id"], note)
            except db.ConnectionLost:
                st.error(
                    "The connection to the database dropped. Reload the page to see whether the decision was stored.",
                    title="Connection lost",
                )
                st.stop()
            if refusal:
                st.error(problem_message(refusal), title="Not done")
            else:
                st.session_state.review_done = f"{p['file_name']} {'approved' if approved else 'rejected'}."
                st.rerun()
