"""The export job's database half against a real database deployed from db/.

Runs only with PATCH_DESK_DB_URL set to a postgresql:// URL of such a
database, as the deploy login. db/local-check.sh runs it after the app's data
layer test (app/tests/test_db_routes.py), which leaves a patch Bob submitted
and Cid approved. The job's own functions read the batch and mark it, as the
deploy login, which provision_principals registered as service.patch_export.
"""

from __future__ import annotations

import os

import pytest
from patch_desk_job import mark_exported, read_export_batch
from test_provision_principals_db import BOB, CID, connect, kernel_rows

URL = os.environ.get("PATCH_DESK_DB_URL", "")
pytestmark = pytest.mark.skipif(not URL, reason="PATCH_DESK_DB_URL is not set")


def test_export_reads_marks_once_and_names_the_export_service():
    import pg8000.exceptions

    deployer = connect()
    try:
        product_count = deployer.run("SELECT api.job_patch_export_batch(false)")[0][0]["product_count"]
        batch, full = read_export_batch(deployer, delta_count=product_count)
        assert not full
        assert batch.patch_ids, "the app's data layer test leaves an approved patch"
        lineage = {p["approved_by"] for p in batch.products if p["patch_id"] in batch.patch_ids}
        assert CID in lineage

        everything, full = read_export_batch(deployer, delta_count=0)
        assert full and len(everything.products) == product_count

        assert mark_exported(deployer, batch.patch_ids) == len(batch.patch_ids)
        assert mark_exported(deployer, batch.patch_ids) == 0
        again, _ = read_export_batch(deployer, delta_count=product_count)
        assert not set(again.patch_ids) & set(batch.patch_ids)

        # The event in the export service's name is checked by
        # db/core/__test__/test_patch_export.sql; here, that the rows changed.
        unmarked = kernel_rows(deployer, """SELECT object_id FROM core.patch
                                            WHERE object_id = ANY (CAST(:ids AS uuid[])) AND exported_at IS NULL""",
                               ids=list(batch.patch_ids))
        assert unmarked == []
        assert kernel_rows(deployer, "SELECT id FROM membership.service_principal WHERE database_role = session_user") \
            == [["service.patch_export"]]
        assert not kernel_rows(deployer, "SELECT FROM membership.database_login WHERE database_role = session_user")
    finally:
        deployer.close()

    # A person's own login (the caller role) cannot call the job routines.
    bob = connect(BOB)
    try:
        for sql in ("SELECT api.job_patch_export_batch(false)",
                    "SELECT api.job_patch_mark_exported(CAST('{}' AS uuid[]))"):
            with pytest.raises(pg8000.exceptions.DatabaseError) as refused:
                bob.run(sql)
            assert refused.value.args[0].get("C") == "42501"
    finally:
        bob.close()
