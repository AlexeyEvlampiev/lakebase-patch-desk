-- Proves: an uploader sees only their own patches, an approver sees the whole organization's, and nobody sees another organization's.
-- ============================================================================
-- Test: who sees which patches, lines and events
-- ============================================================================
-- Tests run as the owner, which runs every handler and is held to the forced
-- policies. In Acme, Uma (patch.uploader) and Ann (patch.approver) each submit
-- a patch; in Globex, Gil (owner) submits one. A submitter sees their own
-- patches, a patch.decide holder every patch of the organization, nobody the
-- other organization's, and a request without an organization nothing.

CREATE FUNCTION pg_temp.patch_seen(p_name text, p_organization uuid)
RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    v_seen text;
BEGIN
    PERFORM pg_temp.patch_act_as(p_name, p_organization);
    SELECT concat_ws(' / ',
        coalesce((SELECT string_agg(file_name, ',' ORDER BY file_name) FROM core.vw_patch), '-'),
        coalesce((SELECT string_agg(p.file_name, ',' ORDER BY p.file_name)
                  FROM core.patch_line l JOIN core.patch p ON p.object_id = l.patch_id), '-'),
        coalesce((SELECT string_agg(p.file_name, ',' ORDER BY p.file_name)
                  FROM core.patch_event e JOIN core.patch p ON p.object_id = e.patch_id), '-'))
    INTO v_seen;
    PERFORM pg_temp.test_act_as(NULL);
    RETURN v_seen;
END $$;

DO $$
DECLARE
    v_acme   uuid := current_setting('test.patch_acme')::uuid;
    v_globex uuid := current_setting('test.patch_globex')::uuid;
    v_line   jsonb := '[{"line_no": 2, "product_code": "P-5001", "field": "name", "new_value": "Dish soap 0.5 l", "reason": "r"}]';
    v_case   record;
    v_got    text;
    v_uma    uuid;
BEGIN
    PERFORM pg_temp.patch_act_as('uma', v_acme);
    v_uma := (core.fn_submit_patch('uma.xlsx', v_line)).object_id;
    PERFORM pg_temp.patch_act_as('ann', v_acme);
    PERFORM core.fn_submit_patch('ann.xlsx', v_line);
    PERFORM pg_temp.patch_act_as('gil', v_globex);
    PERFORM core.fn_submit_patch('gil.xlsx', v_line);
    PERFORM pg_temp.test_act_as(NULL);

    FOR v_case IN SELECT * FROM (VALUES
        ('uma',  v_acme,   'uma.xlsx / uma.xlsx / uma.xlsx'),
        ('ann',  v_acme,   'ann.xlsx,uma.xlsx / ann.xlsx,uma.xlsx / ann.xlsx,uma.xlsx'),
        ('olga', v_acme,   'ann.xlsx,uma.xlsx / ann.xlsx,uma.xlsx / ann.xlsx,uma.xlsx'),
        ('max',  v_acme,   '- / - / -'),
        ('gil',  v_globex, 'gil.xlsx / gil.xlsx / gil.xlsx'),
        ('gil',  v_acme,   '- / - / -'),
        ('uma',  v_globex, '- / - / -'),
        ('ann',  NULL,     '- / - / -')) AS t(person, org, want)
    LOOP
        v_got := pg_temp.patch_seen(v_case.person, v_case.org);
        IF v_got IS DISTINCT FROM v_case.want THEN
            RAISE EXCEPTION 'TEST FAILED: % in % must see patches / lines / events %, got %',
                v_case.person, coalesce(v_case.org::text, 'no organization'), v_case.want, v_got;
        END IF;
    END LOOP;

    -- Ann sees Uma's pending patch and may decide it.
    PERFORM pg_temp.patch_act_as('ann', v_acme);
    IF (SELECT approve_problem FROM core.vw_patch WHERE file_name = 'uma.xlsx' AND state = 'pending') IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: Ann must see Uma''s pending patch with nothing against approving it';
    END IF;

    -- Nobody writes into another organization, whatever the row says.
    PERFORM pg_temp.patch_act_as('uma', v_acme);
    BEGIN
        INSERT INTO core.patch (organization_id, created_by_user_id, file_name, state)
        VALUES (v_globex, current_setting('test.patch_uma_id')::uuid, 'forged.xlsx', 'pending');
        RAISE EXCEPTION 'TEST FAILED: Uma stored a patch in Globex';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    -- Nor in someone else's name.
    BEGIN
        INSERT INTO core.patch (organization_id, created_by_user_id, file_name, state)
        VALUES (v_acme, current_setting('test.patch_ann_id')::uuid, 'forged.xlsx', 'pending');
        RAISE EXCEPTION 'TEST FAILED: Uma stored a patch in Ann''s name';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    -- Gil cannot decide Acme's patch: in Globex he does not see it.
    PERFORM pg_temp.patch_act_as('gil', v_globex);
    IF core.fn_patch_problem(v_uma, 'approve') IS DISTINCT FROM 'core.patch.not_found'
       OR (core.fn_approve_patch(v_uma)).object_id IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: Gil must not see Acme''s patch';
    END IF;
    PERFORM pg_temp.test_act_as(NULL);
    RAISE NOTICE '  + patches: own for submitters, the organization''s for deciders, none across organizations';
END $$;
