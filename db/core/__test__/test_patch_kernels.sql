-- Proves: a person cannot approve their own patch; approval applies only the clean lines, rejection nothing; bad and stale lines are caught.
-- ============================================================================
-- Test: submit, approve and reject, and the rules the kernels and tables keep
-- ============================================================================

-- Submit: a clean file is pending, every line keeps the value seen at upload,
-- and the submitted event names the submitter.
DO $$
DECLARE
    v_acme  uuid := current_setting('test.patch_acme')::uuid;
    v_uma   uuid := current_setting('test.patch_uma_id')::uuid;
    v_patch core.patch;
    v_old   text;
BEGIN
    SELECT unit_price::text INTO STRICT v_old FROM core.product WHERE product_code = 'P-1002';
    PERFORM pg_temp.patch_act_as('uma', v_acme);
    v_patch := core.fn_submit_patch(' prices.xlsx ', '[
        {"line_no": 2, "product_code": " P-1002 ", "field": " Unit_Price ", "new_value": "99.50", "reason": "supplier list"},
        {"line_no": 3, "product_code": "P-1002", "field": "name", "new_value": "Orange juice 1 litre", "reason": "spelling"}]');

    IF v_patch.state IS DISTINCT FROM 'pending' OR v_patch.file_name IS DISTINCT FROM 'prices.xlsx'
       OR v_patch.created_by_user_id IS DISTINCT FROM v_uma OR v_patch.organization_id IS DISTINCT FROM v_acme THEN
        RAISE EXCEPTION 'TEST FAILED: a clean file must be stored pending for Uma in Acme, got %', v_patch;
    END IF;
    IF (SELECT array_agg(l.old_value || '|' || l.field || '|' || coalesce(l.problem, '-') ORDER BY l.line_no)
        FROM core.vw_patch_line l WHERE l.patch_id = v_patch.object_id)
       IS DISTINCT FROM ARRAY[v_old || '|unit_price|-', 'Orange juice 1 l|name|-'] THEN
        RAISE EXCEPTION 'TEST FAILED: lines must keep the value seen at upload, normalized fields and no problem, got %',
            (SELECT array_agg(l ORDER BY l.line_no) FROM core.vw_patch_line l WHERE l.patch_id = v_patch.object_id);
    END IF;
    IF NOT EXISTS (SELECT FROM core.vw_patch_event e WHERE e.patch_id = v_patch.object_id
                   AND e.event = 'submitted' AND e.created_by_user_id = v_uma) THEN
        RAISE EXCEPTION 'TEST FAILED: the submitted event must name Uma';
    END IF;
END $$;

-- Line problems: each line gets the first problem that applies, and a file
-- with any problem is stored as invalid.
DO $$
DECLARE
    v_acme  uuid := current_setting('test.patch_acme')::uuid;
    v_patch core.patch;
    v_got   text[];
    v_want  text[] := ARRAY[
        '2:core.patch_line.product_not_found', '3:core.patch_line.field_unknown', '4:-',
        '5:core.patch_line.duplicate', '6:core.patch_line.reason_required', '7:core.patch_line.value_invalid',
        '8:core.patch_line.value_invalid', '9:core.patch_line.value_invalid', '10:core.patch_line.value_invalid',
        '11:core.patch_line.value_unchanged', '12:core.patch_line.value_invalid', '13:-'];
BEGIN
    PERFORM pg_temp.patch_act_as('uma', v_acme);
    v_patch := core.fn_submit_patch('mixed.xlsx', jsonb_build_array(
        jsonb_build_object('line_no', 2, 'product_code', 'NOPE', 'field', 'name', 'new_value', 'x', 'reason', 'r'),
        jsonb_build_object('line_no', 3, 'product_code', 'P-2001', 'field', 'colour', 'new_value', 'red', 'reason', 'r'),
        jsonb_build_object('line_no', 4, 'product_code', 'P-2001', 'field', 'name', 'new_value', 'Sourdough', 'reason', 'r'),
        jsonb_build_object('line_no', 5, 'product_code', 'P-2001', 'field', 'name', 'new_value', 'Sourdough 2', 'reason', 'r'),
        jsonb_build_object('line_no', 6, 'product_code', 'P-2002', 'field', 'name', 'new_value', 'Croissant', 'reason', ' '),
        jsonb_build_object('line_no', 7, 'product_code', 'P-2002', 'field', 'unit_price', 'new_value', 'NaN', 'reason', 'r'),
        jsonb_build_object('line_no', 8, 'product_code', 'P-2003', 'field', 'unit_price', 'new_value', '-1', 'reason', 'r'),
        jsonb_build_object('line_no', 9, 'product_code', 'P-2004', 'field', 'unit_price', 'new_value', 'cheap', 'reason', 'r'),
        jsonb_build_object('line_no', 10, 'product_code', 'P-2004', 'field', 'category', 'new_value', 'TOYS', 'reason', 'r'),
        jsonb_build_object('line_no', 11, 'product_code', 'P-3001', 'field', 'active', 'new_value', 'true', 'reason', 'r'),
        jsonb_build_object('line_no', 12, 'product_code', 'P-3002', 'field', 'name', 'new_value', '  ', 'reason', 'r'),
        jsonb_build_object('line_no', 13, 'product_code', 'P-3002', 'field', 'active', 'new_value', 'false', 'reason', 'r')));

    -- P-3001 is seeded active and P-3002 too; a kept database may have
    -- changed them, so lines 11 and 13 follow what the catalogue holds now.
    IF NOT (SELECT active FROM core.product WHERE product_code = 'P-3001') THEN
        v_want[10] := '11:-';
    END IF;
    IF NOT (SELECT active FROM core.product WHERE product_code = 'P-3002') THEN
        v_want[12] := '13:core.patch_line.value_unchanged';
    END IF;
    SELECT array_agg(l.line_no || ':' || coalesce(l.problem, '-') ORDER BY l.line_no) INTO v_got
    FROM core.vw_patch_line l WHERE l.patch_id = v_patch.object_id;
    IF v_patch.state IS DISTINCT FROM 'invalid' OR v_got IS DISTINCT FROM v_want THEN
        RAISE EXCEPTION 'TEST FAILED: line problems: want invalid %, got % %', v_want, v_patch.state, v_got;
    END IF;
END $$;

-- A file that cannot be stored: the kernel refuses, core.fn_patch_problems says why.
DO $$
DECLARE
    v_acme uuid := current_setting('test.patch_acme')::uuid;
    v_case record;
    v_got  text;
BEGIN
    PERFORM pg_temp.patch_act_as('uma', v_acme);
    FOR v_case IN SELECT * FROM (VALUES
        (' ', '[{"line_no": 2}]'::jsonb, 'file_name:required'),
        ('f.xlsx', '[]'::jsonb, 'lines:required'),
        ('f.xlsx', '{"line_no": 2}'::jsonb, 'lines:required'),
        ('f.xlsx', '[{"line_no": "two"}]'::jsonb, 'lines:invalid'),
        ('f.xlsx', '[{"line_no": 0}]'::jsonb, 'lines:invalid'),
        ('f.xlsx', '[{"line_no": 2}, {"line_no": 2}]'::jsonb, 'lines:invalid'),
        ('f.xlsx', '[{"line_no": 2}, "text"]'::jsonb, 'lines:invalid')) AS t(file_name, lines, want)
    LOOP
        SELECT string_agg(field || ':' || reason, ',' ORDER BY field) INTO v_got
        FROM core.fn_patch_problems(v_case.file_name, v_case.lines);
        IF v_got IS DISTINCT FROM v_case.want
           OR (core.fn_submit_patch(v_case.file_name, v_case.lines)).object_id IS NOT NULL THEN
            RAISE EXCEPTION 'TEST FAILED: file % %: want % and no patch, got %', v_case.file_name, v_case.lines, v_case.want, v_got;
        END IF;
    END LOOP;
    IF EXISTS (SELECT FROM core.vw_patch WHERE file_name = 'f.xlsx') THEN
        RAISE EXCEPTION 'TEST FAILED: a refused file must store nothing';
    END IF;
END $$;

-- Approve: only a patch.decide holder, never on their own patch, only a
-- pending one; the clean lines reach the catalogue and the event names the
-- approver. A second patch over the same value is then stale.
DO $$
DECLARE
    v_acme   uuid := current_setting('test.patch_acme')::uuid;
    v_ann    uuid := current_setting('test.patch_ann_id')::uuid;
    v_first  core.patch;
    v_second core.patch;
    v_own    core.patch;
    v_done   core.patch;
    v_lines  jsonb := '[{"line_no": 2, "product_code": "P-4001", "field": "unit_price", "new_value": "77.70", "reason": "r"},
                        {"line_no": 3, "product_code": "P-4001", "field": "active", "new_value": "false", "reason": "r"},
                        {"line_no": 4, "product_code": "P-4001", "field": "bogus", "new_value": "1", "reason": "r"}]';
BEGIN
    PERFORM pg_temp.patch_act_as('uma', v_acme);
    v_first := core.fn_submit_patch('a.xlsx', v_lines - 2);
    v_second := core.fn_submit_patch('b.xlsx', v_lines - 2);

    IF core.fn_patch_problem(v_first.object_id, 'approve') IS DISTINCT FROM 'core.patch.not_approver'
       OR (core.fn_approve_patch(v_first.object_id)).object_id IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: an uploader must not approve: got %', core.fn_patch_problem(v_first.object_id, 'approve');
    END IF;

    PERFORM pg_temp.patch_act_as('ann', v_acme);
    v_own := core.fn_submit_patch('own.xlsx', v_lines - 2);
    IF core.fn_patch_problem(v_own.object_id, 'approve') IS DISTINCT FROM 'core.patch.own_patch'
       OR (core.fn_approve_patch(v_own.object_id)).object_id IS NOT NULL
       OR core.fn_patch_problem(v_own.object_id, 'reject') IS DISTINCT FROM 'core.patch.own_patch'
       OR (core.fn_reject_patch(v_own.object_id)).object_id IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: self-approval and self-rejection must be refused as core.patch.own_patch';
    END IF;

    v_done := core.fn_approve_patch(v_first.object_id, 'looks right');
    IF v_done.state IS DISTINCT FROM 'approved' OR v_done.decided_by_user_id IS DISTINCT FROM v_ann
       OR v_done.decided_at IS NULL OR v_done.decision_note IS DISTINCT FROM 'looks right' THEN
        RAISE EXCEPTION 'TEST FAILED: Ann must approve Uma''s patch, got % (problem %)', v_done,
            core.fn_patch_problem(v_first.object_id, 'approve');
    END IF;
    IF (SELECT unit_price::text || '|' || active::text FROM core.product WHERE product_code = 'P-4001')
       IS DISTINCT FROM '77.70|false' THEN
        RAISE EXCEPTION 'TEST FAILED: approval must apply both lines to P-4001, got %',
            (SELECT p FROM core.product p WHERE product_code = 'P-4001');
    END IF;
    IF NOT EXISTS (SELECT FROM core.vw_patch_event e WHERE e.patch_id = v_first.object_id
                   AND e.event = 'approved' AND e.created_by_user_id = v_ann AND e.note = 'looks right') THEN
        RAISE EXCEPTION 'TEST FAILED: the approved event must name Ann and carry the note';
    END IF;

    IF core.fn_patch_problem(v_first.object_id, 'approve') IS DISTINCT FROM 'core.patch.not_pending'
       OR (core.fn_reject_patch(v_first.object_id)).object_id IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: a decided patch must be core.patch.not_pending';
    END IF;
    IF core.fn_patch_problem(v_second.object_id, 'approve') IS DISTINCT FROM 'core.patch.stale'
       OR (SELECT approve_problem FROM core.vw_patch WHERE object_id = v_second.object_id) IS DISTINCT FROM 'core.patch.stale'
       OR (core.fn_approve_patch(v_second.object_id)).object_id IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: a patch over a value changed since upload must be core.patch.stale';
    END IF;

    v_done := core.fn_reject_patch(v_second.object_id, 'stale');
    IF v_done.state IS DISTINCT FROM 'rejected' OR v_done.decided_by_user_id IS DISTINCT FROM v_ann THEN
        RAISE EXCEPTION 'TEST FAILED: a stale patch may still be rejected, got %', v_done;
    END IF;
    IF core.fn_patch_problem(gen_random_uuid(), 'approve') IS DISTINCT FROM 'core.patch.not_found' THEN
        RAISE EXCEPTION 'TEST FAILED: an unknown patch must be core.patch.not_found';
    END IF;
END $$;

-- Reject applies nothing.
DO $$
DECLARE
    v_acme  uuid := current_setting('test.patch_acme')::uuid;
    v_patch core.patch;
    v_name  text;
BEGIN
    SELECT name INTO STRICT v_name FROM core.product WHERE product_code = 'P-4002';
    PERFORM pg_temp.patch_act_as('uma', v_acme);
    v_patch := core.fn_submit_patch('r.xlsx', '[{"line_no": 2, "product_code": "P-4002", "field": "name", "new_value": "Rejected name", "reason": "r"}]');
    PERFORM pg_temp.patch_act_as('olga', v_acme);
    IF (core.fn_reject_patch(v_patch.object_id)).state IS DISTINCT FROM 'rejected'
       OR (SELECT name FROM core.product WHERE product_code = 'P-4002') IS DISTINCT FROM v_name THEN
        RAISE EXCEPTION 'TEST FAILED: the owner (every permission) rejects, and nothing is applied';
    END IF;
END $$;

-- A member without patch.submit cannot store a patch: row-level security refuses.
DO $$
DECLARE
    v_acme uuid := current_setting('test.patch_acme')::uuid;
BEGIN
    PERFORM pg_temp.patch_act_as('max', v_acme);
    BEGIN
        PERFORM core.fn_submit_patch('m.xlsx', '[{"line_no": 2, "product_code": "P-1001", "field": "name", "new_value": "x", "reason": "r"}]');
        RAISE EXCEPTION 'TEST FAILED: a member without patch.submit stored a patch';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
END $$;

-- The tables refuse what the kernels never write: a decision by the
-- submitter, a second clean line for one product and field, and any change
-- to a line or an event.
DO $$
DECLARE
    v_acme       uuid := current_setting('test.patch_acme')::uuid;
    v_ann        uuid := current_setting('test.patch_ann_id')::uuid;
    v_patch      core.patch;
    v_constraint text;
    v_rows       bigint;
BEGIN
    PERFORM pg_temp.patch_act_as('ann', v_acme);
    v_patch := core.fn_submit_patch('own.xlsx', '[{"line_no": 2, "product_code": "P-1001", "field": "name", "new_value": "x", "reason": "r"}]');

    BEGIN
        UPDATE core.patch SET state = 'approved', decided_by_user_id = v_ann, decided_at = now()
        WHERE object_id = v_patch.object_id;
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    END;
    IF v_constraint IS DISTINCT FROM 'patch_four_eyes_check' THEN
        RAISE EXCEPTION 'TEST FAILED: a decision by the submitter must hit patch_four_eyes_check, got %', v_constraint;
    END IF;

    v_constraint := NULL;
    BEGIN
        INSERT INTO core.patch_line (organization_id, patch_id, line_no, product_code, field, new_value, reason)
        VALUES (v_acme, v_patch.object_id, 3, 'P-1001', 'name', 'y', 'r');
    EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    END;
    IF v_constraint IS DISTINCT FROM 'patch_line_product_field_key' THEN
        RAISE EXCEPTION 'TEST FAILED: a second clean line for P-1001 name must hit patch_line_product_field_key, got %', v_constraint;
    END IF;

    v_constraint := NULL;
    BEGIN
        UPDATE core.patch SET state = 'pending', exported_at = now() WHERE object_id = v_patch.object_id;
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    END;
    IF v_constraint IS DISTINCT FROM 'patch_exported_check' THEN
        RAISE EXCEPTION 'TEST FAILED: an exported patch that is not approved must hit patch_exported_check, got %', v_constraint;
    END IF;

    UPDATE core.patch_line SET new_value = 'z' WHERE patch_id = v_patch.object_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows IS DISTINCT FROM 0::bigint THEN
        RAISE EXCEPTION 'TEST FAILED: a patch line must never change, % changed', v_rows;
    END IF;
    DELETE FROM core.patch_event WHERE patch_id = v_patch.object_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows IS DISTINCT FROM 0::bigint THEN
        RAISE EXCEPTION 'TEST FAILED: the audit trail is append-only, % event(s) deleted', v_rows;
    END IF;
END $$;
