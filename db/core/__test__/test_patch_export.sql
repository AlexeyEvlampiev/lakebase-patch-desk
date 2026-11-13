-- Proves: only the export job's routines read and mark approved patches across organizations, each patch once; nobody else may call them.
-- ============================================================================
-- Test: the export job's routines read and mark approved patches across
-- organizations, outside any request, and nobody else may call them
-- ============================================================================
-- Approved patches in two organizations, plus a pending and a rejected one.
-- Outside a request, api.job_patch_export_batch lists both approved patches
-- and the products they changed with their approver; api.job_patch_mark_exported
-- marks them in the name of the login's registered service principal, once.
-- A kept database may hold real patches: checks look at this test's own.

DO $$
DECLARE
    v_acme     uuid := current_setting('test.patch_acme')::uuid;
    v_globex   uuid := current_setting('test.patch_globex')::uuid;
    v_gwen     uuid := pg_temp.test_login('test', 'patch-gwen', 'gwen@patch.example.test', 'Gwen', true);
    v_a        core.patch;
    v_g        core.patch;
    v_pending  core.patch;
    v_rejected core.patch;
    v_batch    jsonb;
    v_full     jsonb;
    v_service  membership.service_principal;
    v_marked   integer;
    v_row      jsonb;
    v_price    text;
BEGIN
    PERFORM membership.fn_add_member(v_globex, v_gwen, 'patch.uploader');

    -- Acme: Uma submits, Ann approves. Globex: Gwen submits, Gil approves.
    SELECT (unit_price + 1)::text INTO STRICT v_price FROM core.product WHERE product_code = 'P-2002';
    PERFORM pg_temp.patch_act_as('uma', v_acme);
    v_a := core.fn_submit_patch('export-a.xlsx', jsonb_build_array(jsonb_build_object(
        'line_no', 2, 'product_code', 'P-2002', 'field', 'unit_price', 'new_value', v_price, 'reason', 'export test')));
    v_pending := core.fn_submit_patch('export-pending.xlsx', '[
        {"line_no": 2, "product_code": "P-2004", "field": "name", "new_value": "Pending export", "reason": "export test"}]');
    v_rejected := core.fn_submit_patch('export-rejected.xlsx', '[
        {"line_no": 2, "product_code": "P-3001", "field": "name", "new_value": "Rejected export", "reason": "export test"}]');
    PERFORM pg_temp.patch_act_as('ann', v_acme);
    v_a := core.fn_approve_patch(v_a.object_id);
    v_rejected := core.fn_reject_patch(v_rejected.object_id);

    PERFORM pg_temp.patch_act_as('gwen', v_globex);
    v_g := core.fn_submit_patch('export-g.xlsx', '[
        {"line_no": 2, "product_code": "P-2003", "field": "name", "new_value": "Globex export name", "reason": "export test"}]');
    PERFORM pg_temp.patch_act_as('gil', v_globex);
    v_g := core.fn_approve_patch(v_g.object_id);
    IF v_a.state IS DISTINCT FROM 'approved' OR v_g.state IS DISTINCT FROM 'approved'
       OR v_pending.state IS DISTINCT FROM 'pending' OR v_rejected.state IS DISTINCT FROM 'rejected' THEN
        RAISE EXCEPTION 'TEST FAILED: setup: want approved, approved, pending, rejected, got % % % %',
            v_a.state, v_g.state, v_pending.state, v_rejected.state;
    END IF;

    -- Outside any request, as the job runs.
    PERFORM pg_temp.test_act_as(NULL);
    v_batch := api.job_patch_export_batch(false);
    IF NOT v_batch -> 'patch_ids' @> jsonb_build_array(v_a.object_id, v_g.object_id)
       OR v_batch -> 'patch_ids' @> jsonb_build_array(v_pending.object_id)
       OR v_batch -> 'patch_ids' @> jsonb_build_array(v_rejected.object_id) THEN
        RAISE EXCEPTION 'TEST FAILED: the batch must list both organizations'' approved patches and no other, got %',
            v_batch -> 'patch_ids';
    END IF;
    IF (v_batch ->> 'product_count')::bigint IS DISTINCT FROM (SELECT count(*) FROM core.product) THEN
        RAISE EXCEPTION 'TEST FAILED: product_count must count the catalogue, got %', v_batch -> 'product_count';
    END IF;
    SELECT p INTO v_row FROM jsonb_array_elements(v_batch -> 'products') p WHERE p ->> 'product_code' = 'P-2002';
    IF v_row ->> 'unit_price' IS DISTINCT FROM v_price
       OR v_row ->> 'patch_id' IS DISTINCT FROM v_a.object_id::text
       OR v_row ->> 'approved_by' IS DISTINCT FROM 'ann@patch.example.test'
       OR (v_row ->> 'approved_at')::timestamptz IS DISTINCT FROM v_a.decided_at THEN
        RAISE EXCEPTION 'TEST FAILED: P-2002 must carry the new price and Ann''s approval as lineage, got %', v_row;
    END IF;
    SELECT p INTO v_row FROM jsonb_array_elements(v_batch -> 'products') p WHERE p ->> 'product_code' = 'P-2003';
    IF v_row ->> 'name' IS DISTINCT FROM 'Globex export name' OR v_row ->> 'approved_by' IS DISTINCT FROM 'gil@patch.example.test' THEN
        RAISE EXCEPTION 'TEST FAILED: P-2003 must carry Globex''s approved name and Gil as approver, got %', v_row;
    END IF;
    -- P-2004 and P-3001 are only in the pending and the rejected patch (a
    -- kept database's own approved patches may name them too: then they carry
    -- that patch as lineage).
    IF EXISTS (SELECT FROM jsonb_array_elements(v_batch -> 'products') p
               WHERE p ->> 'product_code' IN ('P-2004', 'P-3001') AND p ->> 'patch_id' IS NULL) THEN
        RAISE EXCEPTION 'TEST FAILED: products of pending or rejected patches must not be in the batch';
    END IF;

    v_full := api.job_patch_export_batch(true);
    IF jsonb_array_length(v_full -> 'products') IS DISTINCT FROM (v_full ->> 'product_count')::int THEN
        RAISE EXCEPTION 'TEST FAILED: a full batch must hold every product, got % of %',
            jsonb_array_length(v_full -> 'products'), v_full -> 'product_count';
    END IF;

    -- Marking needs the login to be a registered service principal (read
    -- as the kernel: the owner sees no service principal outside a request).
    IF NOT internal.service_registered(session_user) THEN
        v_marked := api.job_patch_mark_exported(ARRAY[v_a.object_id]);
        IF v_marked IS NOT NULL THEN
            RAISE EXCEPTION 'TEST FAILED: a login that is no registered service principal must mark nothing, got %', v_marked;
        END IF;
    END IF;
    v_service := membership.fn_register_service_principal('service.patch_export', 'Patch desk export job', session_user);
    IF v_service.principal_object_id IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: the session''s login must register as service.patch_export';
    END IF;

    v_marked := api.job_patch_mark_exported(ARRAY[v_a.object_id, v_g.object_id, v_pending.object_id, v_rejected.object_id]);
    IF v_marked IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'TEST FAILED: marking must mark exactly the two approved patches, got %', v_marked;
    END IF;
    v_marked := api.job_patch_mark_exported(ARRAY[v_a.object_id, v_g.object_id]);
    IF v_marked IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'TEST FAILED: marking twice must change nothing, got %', v_marked;
    END IF;
    v_batch := api.job_patch_export_batch(false);
    IF v_batch -> 'patch_ids' @> jsonb_build_array(v_a.object_id)
       OR v_batch -> 'patch_ids' @> jsonb_build_array(v_g.object_id) THEN
        RAISE EXCEPTION 'TEST FAILED: exported patches must leave the batch, got %', v_batch -> 'patch_ids';
    END IF;

    -- The trail, read as each organization's approver: one exported event in
    -- the export service's name; the pending patch is untouched.
    PERFORM pg_temp.patch_act_as('ann', v_acme);
    IF (SELECT exported_at FROM core.vw_patch WHERE object_id = v_a.object_id) IS NULL
       OR (SELECT exported_at FROM core.vw_patch WHERE object_id = v_pending.object_id) IS NOT NULL
       OR (SELECT array_agg(e.created_by_user_id) FROM core.vw_patch_event e
           WHERE e.patch_id = v_a.object_id AND e.event = 'exported')
          IS DISTINCT FROM ARRAY[v_service.principal_object_id] THEN
        RAISE EXCEPTION 'TEST FAILED: Acme''s patch must be exported once in the export service''s name';
    END IF;
    PERFORM pg_temp.patch_act_as('gil', v_globex);
    IF (SELECT count(*) FROM core.vw_patch_event e WHERE e.patch_id = v_g.object_id AND e.event = 'exported') <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED: Globex''s patch must be exported once';
    END IF;

    -- Requests are still held by the restrictive policies: an Acme member
    -- without patch.decide sees nobody else's patch, Globex sees none of Acme's.
    PERFORM pg_temp.patch_act_as('max', v_acme);
    IF EXISTS (SELECT FROM core.vw_patch WHERE object_id = v_a.object_id) THEN
        RAISE EXCEPTION 'TEST FAILED: a member without patch.decide must not see another''s patch';
    END IF;
    IF EXISTS (SELECT FROM core.vw_patch WHERE object_id = v_g.object_id) THEN
        RAISE EXCEPTION 'TEST FAILED: Acme must not see Globex''s patch';
    END IF;
    PERFORM pg_temp.test_act_as(NULL);
END $$;

-- Only the owner (and the logins that inherit it) and a registered jobs login
-- run the job routines; the kernels behind them only the owner. Not the
-- gateway, not the caller role every mapped person holds, not PUBLIC.
DO $$
DECLARE
    v_routine text;
    v_role    text;
BEGIN
    FOREACH v_routine IN ARRAY ARRAY['api.job_patch_export_batch(boolean)', 'api.job_patch_mark_exported(uuid[])',
                                     'core.fn_patch_export_batch(boolean)', 'core.fn_mark_patches_exported(uuid[])'] LOOP
        FOREACH v_role IN ARRAY ARRAY[pg_temp.deployment_setting('database_caller_role'),
                                      pg_temp.deployment_setting('database_api_role'), 'public'] LOOP
            IF has_function_privilege(v_role, v_routine, 'EXECUTE') THEN
                RAISE EXCEPTION 'TEST FAILED: % must not execute %', v_role, v_routine;
            END IF;
        END LOOP;
        IF NOT has_function_privilege(pg_temp.deployment_setting('database_owner_role'), v_routine, 'EXECUTE') THEN
            RAISE EXCEPTION 'TEST FAILED: the owner must execute %', v_routine;
        END IF;
    END LOOP;
END $$;
