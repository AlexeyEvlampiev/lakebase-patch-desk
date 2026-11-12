/*
<pgmi-meta id="c4a81f6e-2b3d-4e95-9a07-5f1d8e2c7b46" idempotent="true">
  <description>The export job's entry points: api.job_patch_export_batch and api.job_patch_mark_exported over the export kernels.</description>
  <sortKeys><key>005/100/patch/7</key></sortKeys>
</pgmi-meta>
*/
-- The patch_export job (jobs/patch_desk_job.py export) calls these two and
-- nothing else in the database. They are api.job_* routines: no request
-- context, no auth.* setting or header (lib/__test__/test_handler_context_reads.sql),
-- and a registered jobs login (README: The jobs login) would be granted them.
-- On the demo the job runs as the deploy login, which reaches them as a
-- member of the owner, like the admin login the README names for schedulers.
-- The deploy login cannot be the jobs login: it executes every routine
-- through the owner, and lib/__test__/test_exact_grants.sql refuses that.
-- Plain functions, not the batched procedures api.job_run drives: the job
-- reads one batch, merges it in the lakehouse, then marks it.

-- The approved, not yet exported patches and the products they changed
-- (every product when p_full), plus the product count (core.fn_patch_export_batch).
CREATE OR REPLACE FUNCTION api.job_patch_export_batch(p_full boolean)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = core, common, pg_temp
AS $$
    SELECT core.fn_patch_export_batch(coalesce(p_full, false));
$$;
COMMENT ON FUNCTION api.job_patch_export_batch(boolean) IS
    'The export job''s batch: {patch_ids, product_count, products}, the approved unexported patches and the products they changed, or every product when p_full.';

-- Marks the patches exported in the name of the login's registered service
-- principal; how many it marked, 0 on a repeat, NULL when the login is no
-- registered service principal (core.fn_mark_patches_exported).
CREATE OR REPLACE FUNCTION api.job_patch_mark_exported(p_patch_ids uuid[])
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
SET search_path = core, common, pg_temp
AS $$
    SELECT core.fn_mark_patches_exported(coalesce(p_patch_ids, '{}'));
$$;
COMMENT ON FUNCTION api.job_patch_mark_exported(uuid[]) IS
    'Marks approved, unexported patches exported after the export job''s merge; the count marked, NULL when the login is no registered service principal.';
