# app: the Databricks App

A thin Streamlit app. Every page works as the signed-in person over that
person's own database connection; the business rules and checks live in
PostgreSQL ([`../db/`](../db/README.md)).

| File | What it does |
|---|---|
| `streamlit_app.py` | entry point: the pages and the navigation |
| `db.py` | the database connection as the signed-in person (forwarded token, `postgres` scope, short-lived database credential) and one call per patch desk operation, through `api.rest_invoke` |
| `app_pages/` | Home, Upload, My requests (`my_patches.py`), Review, History |
| `excel.py` | reads an uploaded `.xlsx` and builds the sample file; checks only its shape |
| `labels.py`, `messages.py` | plain words for the codes the database returns |
| `session_watch.py` | reloads an open tab after the app restarts |
| `app.yaml` | how Databricks Apps runs the app: the Lakebase endpoint and database |
| `requirements.txt` | pinned packages the Apps runtime installs |
| `tests/` | unit tests; `test_db_routes.py` also runs against a real database |

Start with `streamlit_app.py`, then `db.py`.

Run the unit tests from the repo root:

```bash
uv run --with pytest --with-requirements app/requirements.txt pytest app/tests
```

`test_db_routes.py` skips unless `PATCH_DESK_DB_URL` points at a database;
`db/local-check.sh` sets it up and runs it.
