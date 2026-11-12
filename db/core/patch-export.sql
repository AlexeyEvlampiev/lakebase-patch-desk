/*
<pgmi-meta id="7d2e9a14-3c8b-4f60-a51e-2b9c6d0f4e73" idempotent="true">
  <description>Export kernels: the approved, not yet exported patches with the products they changed, and marking them exported. Across organizations, as the kernel role.</description>
  <sortKeys><key>005/100/patch/6</key></sortKeys>
</pgmi-meta>
*/
-- The patch_export job (jobs/patch_desk_job.py export) copies products to the
-- lakehouse. It runs outside any request, so these kernels are SECURITY
-- DEFINER, owned by the kernel role (pg_temp.kernel_owns) and let past
-- row-level security by core/patch-export-structure.sql. They read no
-- request context. Only the owner executes them; the job reaches them through
-- api.job_patch_export_batch and api.job_patch_mark_exported.

-- One consistent batch: the approved patches not yet exported, and the
-- current product rows they touched (every product when p_full), each with
-- the latest approved patch that touched it as lineage. Also the number of
-- products, so the job can tell when its copy is incomplete. The job merges
-- the products, then marks exactly these patch ids; a patch approved during
-- the run is in neither list, and the next run picks it up.
--
-- Current rows, not line values: two patches on one product give one row,
-- so the MERGE source has unique keys, and a repeat sets the same values.
-- Prices travel as text, so JSON numbers never round them. approved_by is the
-- approver's email, else their display name (core.fn_patch_person_name's rule).
CREATE OR REPLACE FUNCTION core.fn_patch_export_batch(p_full boolean)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = core, membership, common, pg_temp
AS $$
    WITH pending AS (
        SELECT p.object_id AS patch_id
        FROM core.patch p
        WHERE p.state = 'approved' AND p.exported_at IS NULL
    ),
    lineage AS (
        SELECT DISTINCT ON (l.product_code)
               l.product_code, p.object_id AS patch_id,
               coalesce(up.email::text, pr.display_name) AS approved_by, p.decided_at AS approved_at
        FROM core.patch_line l
        JOIN core.patch p ON p.organization_id = l.organization_id AND p.object_id = l.patch_id
        LEFT JOIN membership.principal pr ON pr.object_id = p.decided_by_user_id
        LEFT JOIN membership.user_principal up ON up.principal_object_id = p.decided_by_user_id
        WHERE p.state = 'approved' AND l.problem IS NULL
        ORDER BY l.product_code, p.decided_at DESC, p.object_id DESC
    ),
    products AS (
        SELECT pd.product_code, pd.name, pd.category, pd.unit_price, pd.active, pd.updated_at,
               lin.patch_id, lin.approved_by, lin.approved_at
        FROM core.product pd
        LEFT JOIN lineage lin ON lin.product_code = pd.product_code
        WHERE p_full
           OR pd.product_code IN (SELECT l.product_code
                                  FROM core.patch_line l
                                  JOIN pending pe ON pe.patch_id = l.patch_id
                                  WHERE l.problem IS NULL)
    )
    SELECT jsonb_build_object(
        'patch_ids',     coalesce((SELECT jsonb_agg(patch_id ORDER BY patch_id) FROM pending), '[]'::jsonb),
        'product_count', (SELECT count(*) FROM core.product),
        'products',      coalesce((SELECT jsonb_agg(jsonb_build_object(
                                       'product_code', product_code,
                                       'name',         name,
                                       'category',     category,
                                       'unit_price',   unit_price::text,
                                       'active',       active,
                                       'updated_at',   updated_at,
                                       'patch_id',     patch_id,
                                       'approved_by',  approved_by,
                                       'approved_at',  approved_at)
                                       ORDER BY product_code)
                                   FROM products), '[]'::jsonb));
$$;
SELECT pg_temp.kernel_owns('core.fn_patch_export_batch(boolean)');

-- Mark patches exported after the merge committed: sets exported_at and adds
-- one 'exported' event each, in the name of the service principal registered
-- for the session's login (membership.fn_register_service_principal; the
-- db_deploy job's provisioning registers the deploy login as
-- service.patch_export). Ids that are not approved or already exported are
-- skipped, so a repeat changes nothing. Returns how many it marked, or NULL
-- when the login is no enabled registered service principal (nothing marked).
CREATE OR REPLACE FUNCTION core.fn_mark_patches_exported(p_patch_ids uuid[])
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
SET search_path = core, membership, common, pg_temp
AS $$
    WITH exporter AS (
        SELECT s.principal_object_id
        FROM membership.service_principal s
        JOIN membership.principal p ON p.object_id = s.principal_object_id
        WHERE s.database_role = session_user AND p.disabled_at IS NULL
    ),
    marked AS (
        UPDATE core.patch p
        SET exported_at = now()
        WHERE p.object_id = ANY (p_patch_ids)
          AND p.state = 'approved'
          AND p.exported_at IS NULL
          AND EXISTS (SELECT FROM exporter)
        RETURNING p.organization_id, p.object_id
    ),
    events AS (
        INSERT INTO core.patch_event (organization_id, patch_id, created_by_user_id, event)
        SELECT m.organization_id, m.object_id, e.principal_object_id, 'exported'
        FROM marked m CROSS JOIN exporter e
        RETURNING 1
    )
    SELECT CASE WHEN EXISTS (SELECT FROM exporter) THEN (SELECT count(*)::integer FROM events) END;
$$;
SELECT pg_temp.kernel_owns('core.fn_mark_patches_exported(uuid[])');
