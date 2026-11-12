"""The patch desk: business users upload Excel files with product fixes.

Every page works as the signed-in user over their own database connection
(db.Desk, one per session). Row-level security in Postgres decides what
each person sees.
"""

import labels
import streamlit as st
from session_watch import watch_session

import db

APP_NAME = "Product data desk"
APP_ICON = ":material/inventory_2:"

st.set_page_config(page_title=APP_NAME, page_icon=APP_ICON, layout="wide")
st.logo(APP_ICON, size="large")
watch_session()  # recover the tab after an app restart instead of hanging

if "desk" not in st.session_state:
    try:
        token = db.user_token(st.context.headers)
    except db.NotInApp:
        st.error("Open this app from Databricks.", title="No sign-in")
        st.stop()
    desk = db.Desk(token, forwarded_email=st.context.headers.get(db.EMAIL_HEADER))
    try:
        desk.connect()
        allowed = desk.has_access()
    except db.NoAccess:
        allowed = False
    except db.DatabricksRefused as e:
        st.warning(
            f"Databricks did not give your account a database login: {e}\n\n"
            "Ask the workspace admin to check your access.",
            title="No database login",
        )
        st.stop()
    except db.Unavailable:
        st.warning(
            "The database did not answer in time. It may be waking up after a quiet spell. Try again in a moment.",
            title="Not reachable right now",
        )
        st.button("Try again", icon=":material/refresh:")
        st.stop()
    except db.SignInExpired:
        st.warning("Your sign-in has expired. Reload the page.", title="Signed out")
        st.stop()
    if not allowed:
        desk.close()
        st.info(
            f"You do not have access to the {APP_NAME} yet. Ask to be added to `patch-desk-uploaders`.",
            title="No access yet",
        )
        st.stop()
    st.session_state.desk = desk

desk = st.session_state.desk
pages = [
    st.Page(
        "app_pages/home.py",
        title="Home",
        icon=":material/home:",
        default=True,
        help="What needs your attention: requests to review, and your rejected requests.",
    ),
    st.Page(
        "app_pages/upload.py",
        title="Upload",
        icon=":material/upload_file:",
        help="Upload an Excel file with product fixes and see at once which lines are fine.",
    ),
    st.Page(
        "app_pages/my_patches.py",
        title="My requests",
        icon=":material/folder_open:",
        help="The files you uploaded, their state and each line's result.",
    ),
]
if desk.is_approver():
    pages.append(
        st.Page(
            "app_pages/review.py",
            title="Review",
            icon=":material/fact_check:",
            help="Change requests waiting for a decision. Approve or reject other people's requests with a note.",
        )
    )
pages.append(
    st.Page(
        "app_pages/history.py",
        title="History",
        icon=":material/history:",
        help="Who submitted, approved, rejected or exported which change request, and when.",
    )
)

page = st.navigation(pages, position="top")
st.title(page.title)  # the navigation already shows each page icon
st.caption(f"{APP_NAME}, signed in as {labels.person(desk.user)}")
page.run()
