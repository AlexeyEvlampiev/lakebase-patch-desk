-- Proves: the patch desk's REST routes, RPC methods and MCP tools submit, list, approve and reject with the same rules and coded refusals.
-- ============================================================================
-- Test: the patch desk through its entry functions (api/patch-desk.sql)
-- ============================================================================
-- Over the Alice fixture (Alice owns Acme Corp, Bob is a member without patch
-- permissions), this test adds Uma (patch.uploader) and Ann (patch.approver)
-- to Acme, and Gil, who owns another organization. Then:
--   REST: a submitter submits, checks a draft and lists her patches, and
--   cannot list pending patches or decide; an approver lists pending
--   patches and approves, and cannot decide her own patch or one twice; a
--   decided patch shows in the history; another organization sees nothing.
--   RPC and MCP: the same kernels answer, with their own refusals.
-- ============================================================================

DO $$
DECLARE
    v_acme   uuid := current_setting('test.acme_org_id')::uuid;
    v_globex uuid;
    v_uma    extensions.hstore;
    v_ann    extensions.hstore;
    v_gil    extensions.hstore;
    v_bob    extensions.hstore;
    v_r      api.http_response;
    v_body   jsonb;
    v_patch  uuid;
    v_own    uuid;
    v_rpc    uuid;
    v_mcp    jsonb;
    v_env    jsonb;
    v_clean  jsonb := '[{"line_no": 1, "product_code": "T-API-1", "field": "unit_price", "new_value": "2.50", "reason": "supplier price"}]';
    -- After v_clean is approved (2.50), a further change.
    v_next   jsonb := '[{"line_no": 1, "product_code": "T-API-1", "field": "unit_price", "new_value": "2.75", "reason": "supplier price"}]';
BEGIN
    RAISE DEBUG '-> Patch desk handlers';
    PERFORM pg_temp.test_act_as(NULL);
    PERFORM core.fn_add_product('T-API-1', 'Test cola', 'BEV', 2.00);
    PERFORM core.fn_add_product('T-API-2', 'Test bread', 'BAKE', 3.00);
    PERFORM membership.fn_add_member(v_acme, pg_temp.test_login('google', 'pd-uma', 'uma@acme.example.test', 'Uma', true), 'patch.uploader');
    PERFORM membership.fn_add_member(v_acme, pg_temp.test_login('google', 'pd-ann', 'ann@acme.example.test', 'Ann', true), 'patch.approver');
    v_globex := (membership.fn_create_organization_with_owner('Globex PD', 'globex-pd',
                     pg_temp.test_login('google', 'pd-gil', 'gil@globex.example.test', 'Gil', true))).object_id;
    v_uma := pg_temp.test_session_headers('google|pd-uma', v_acme);
    v_ann := pg_temp.test_session_headers('google|pd-ann', v_acme);
    v_gil := pg_temp.test_session_headers('google|pd-gil', v_globex);
    v_bob := pg_temp.test_session_headers(current_setting('test.bob_subject'), v_acme);

    -- Who am I.
    v_r := api.rest_invoke('GET', '/patch-desk/me', v_uma, NULL::bytea);
    v_body := api.content_json((v_r).content);
    IF (v_r).status_code IS DISTINCT FROM 200 OR v_body->>'name' IS DISTINCT FROM 'uma@acme.example.test'
       OR v_body->'can_submit' IS DISTINCT FROM 'true'::jsonb OR v_body->'can_decide' IS DISTINCT FROM 'false'::jsonb
       OR v_body->>'actor_kind' IS DISTINCT FROM 'human' THEN
        RAISE EXCEPTION 'TEST FAILED: GET /patch-desk/me for Uma: want submit only, got % %', (v_r).status_code, v_body;
    END IF;
    v_body := api.content_json((api.rest_invoke('GET', '/patch-desk/me', v_bob, NULL::bytea)).content);
    IF v_body->'can_submit' IS DISTINCT FROM 'false'::jsonb OR v_body->'can_decide' IS DISTINCT FROM 'false'::jsonb THEN
        RAISE EXCEPTION 'TEST FAILED: Bob holds no patch permission, got %', v_body;
    END IF;

    -- Categories, for any member.
    v_body := api.content_json((api.rest_invoke('GET', '/patch-categories', v_bob, NULL::bytea)).content);
    IF NOT v_body->'categories' @> '[{"code": "BEV", "name": "Beverages"}]'::jsonb THEN
        RAISE EXCEPTION 'TEST FAILED: GET /patch-categories must list BEV, got %', v_body;
    END IF;

    -- A draft is checked line by line; nothing is stored.
    v_r := api.rest_invoke('POST', '/patches/check', v_uma,
        '{"lines": [{"line_no": 1, "product_code": "NOPE", "field": "name", "new_value": "x", "reason": "r"},
                    {"line_no": 2, "product_code": "T-API-1", "field": "unit_price", "new_value": "2.00", "reason": "r"},
                    {"line_no": 3, "product_code": "T-API-2", "field": "name", "new_value": "Rye", "reason": "rename"}]}'::jsonb);
    v_body := api.content_json((v_r).content);
    IF (v_r).status_code IS DISTINCT FROM 200 OR (v_body->>'problem_count')::int IS DISTINCT FROM 2
       OR v_body->'lines' IS DISTINCT FROM
          '[{"line_no": 1, "problem": "core.patch_line.product_not_found"},
            {"line_no": 2, "problem": "core.patch_line.value_unchanged"},
            {"line_no": 3, "problem": null}]'::jsonb THEN
        RAISE EXCEPTION 'TEST FAILED: POST /patches/check: want one problem per line, got % %', (v_r).status_code, v_body;
    END IF;

    -- Submit: a file that cannot be stored, then a clean one.
    v_r := api.rest_invoke('POST', '/patches', v_uma, jsonb_build_object('file_name', '  ', 'lines', v_clean));
    v_body := api.content_json((v_r).content);
    IF (v_r).status_code IS DISTINCT FROM 422 OR v_body->'invalid-params' IS DISTINCT FROM '[{"name": "file_name", "reason": "required"}]'::jsonb THEN
        RAISE EXCEPTION 'TEST FAILED: a blank file name must be 422 naming file_name, got % %', (v_r).status_code, v_body;
    END IF;
    v_r := api.rest_invoke('POST', '/patches', v_uma, jsonb_build_object('file_name', 'prices.xlsx', 'lines', v_clean));
    v_body := api.content_json((v_r).content);
    v_patch := (v_body->>'patch_id')::uuid;
    IF (v_r).status_code IS DISTINCT FROM 201 OR v_body->>'state' IS DISTINCT FROM 'pending'
       OR v_body->>'submitted_by' IS DISTINCT FROM 'uma@acme.example.test' OR v_body->'own' IS DISTINCT FROM 'true'::jsonb
       OR v_body->'by_agent' IS DISTINCT FROM 'false'::jsonb OR (v_body->>'line_count')::int IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'TEST FAILED: POST /patches: want 201 pending, got % %', (v_r).status_code, v_body;
    END IF;

    -- The submitter lists her patches; pending patches and decisions are not hers.
    v_body := api.content_json((api.rest_invoke('GET', '/patches/mine', v_uma, NULL::bytea)).content);
    IF (v_body->>'total')::int IS DISTINCT FROM 1 OR (v_body->'items'->0->>'patch_id')::uuid IS DISTINCT FROM v_patch THEN
        RAISE EXCEPTION 'TEST FAILED: GET /patches/mine for Uma: want her one patch, got %', v_body;
    END IF;
    v_r := api.rest_invoke('GET', '/patches/pending', v_uma, NULL::bytea);
    IF (v_r).status_code IS DISTINCT FROM 403 THEN
        RAISE EXCEPTION 'TEST FAILED: GET /patches/pending for a submitter must be 403, got %', (v_r).status_code;
    END IF;
    v_r := api.rest_invoke('POST', '/patches/' || v_patch || '/approve', v_uma, '{}'::jsonb);
    IF (v_r).status_code IS DISTINCT FROM 403 OR api.content_json((v_r).content)->>'code' IS DISTINCT FROM 'pgmi.forbidden' THEN
        RAISE EXCEPTION 'TEST FAILED: a submitter approving must be 403 pgmi.forbidden, got % %', (v_r).status_code, api.content_json((v_r).content);
    END IF;

    -- The approver: her own patch is refused, Uma's is approved once.
    v_body := api.content_json((api.rest_invoke('POST', '/patches', v_ann,
        '{"file_name": "bread.xlsx", "lines": [{"line_no": 1, "product_code": "T-API-2", "field": "name", "new_value": "Rye", "reason": "rename"}]}'::jsonb)).content);
    v_own := (v_body->>'patch_id')::uuid;
    v_body := api.content_json((api.rest_invoke('GET', '/patches/pending', v_ann, NULL::bytea)).content);
    IF (v_body->>'total')::int IS DISTINCT FROM 2
       OR (v_body->'items'->0->>'patch_id')::uuid IS DISTINCT FROM v_patch
       OR v_body->'items'->0->'own' IS DISTINCT FROM 'false'::jsonb
       OR v_body->'items'->0->'approve_problem' IS DISTINCT FROM 'null'::jsonb
       OR v_body->'items'->1->>'approve_problem' IS DISTINCT FROM 'core.patch.own_patch' THEN
        RAISE EXCEPTION 'TEST FAILED: GET /patches/pending for Ann: want Uma''s first, approvable, then her own, got %', v_body;
    END IF;
    v_r := api.rest_invoke('POST', '/patches/' || v_own || '/approve', v_ann, '{}'::jsonb);
    IF (v_r).status_code IS DISTINCT FROM 403 OR api.content_json((v_r).content)->>'code' IS DISTINCT FROM 'core.patch.own_patch' THEN
        RAISE EXCEPTION 'TEST FAILED: approving one''s own patch must be 403 core.patch.own_patch, got % %', (v_r).status_code, api.content_json((v_r).content);
    END IF;
    v_r := api.rest_invoke('POST', '/patches/' || v_patch || '/approve', v_ann, '{"note": "ok"}'::jsonb);
    v_body := api.content_json((v_r).content);
    IF (v_r).status_code IS DISTINCT FROM 200 OR v_body->>'state' IS DISTINCT FROM 'approved'
       OR v_body->>'decided_by' IS DISTINCT FROM 'ann@acme.example.test' OR v_body->>'decision_note' IS DISTINCT FROM 'ok' THEN
        RAISE EXCEPTION 'TEST FAILED: approving Uma''s patch: want 200 approved by Ann, got % %', (v_r).status_code, v_body;
    END IF;
    v_r := api.rest_invoke('POST', '/patches/' || v_patch || '/reject', v_ann, '{}'::jsonb);
    IF (v_r).status_code IS DISTINCT FROM 409 OR api.content_json((v_r).content)->>'code' IS DISTINCT FROM 'core.patch.not_pending' THEN
        RAISE EXCEPTION 'TEST FAILED: deciding twice must be 409 core.patch.not_pending, got % %', (v_r).status_code, api.content_json((v_r).content);
    END IF;
    v_r := api.rest_invoke('POST', '/patches/' || gen_random_uuid() || '/reject', v_ann, '{}'::jsonb);
    IF (v_r).status_code IS DISTINCT FROM 404 OR api.content_json((v_r).content)->>'code' IS DISTINCT FROM 'core.patch.not_found' THEN
        RAISE EXCEPTION 'TEST FAILED: an unknown patch must be 404 core.patch.not_found, got % %', (v_r).status_code, api.content_json((v_r).content);
    END IF;

    -- The catalogue changed; the lines and the history say so.
    v_body := api.content_json((api.rest_invoke('GET', '/patches/' || v_patch || '/lines', v_uma, NULL::bytea)).content);
    IF v_body->'lines'->0->>'current_value' IS DISTINCT FROM '2.50' OR v_body->'lines'->0->>'old_value' IS DISTINCT FROM '2.00'
       OR v_body->'patch'->>'state' IS DISTINCT FROM 'approved' THEN
        RAISE EXCEPTION 'TEST FAILED: GET /patches/{id}/lines after approval: want 2.00 -> 2.50, got %', v_body;
    END IF;
    v_body := api.content_json((api.rest_invoke('GET', '/patch-events', v_uma, NULL::bytea)).content);
    IF (v_body->>'total')::int IS DISTINCT FROM 2
       OR v_body->'items'->0->>'event' IS DISTINCT FROM 'approved' OR v_body->'items'->0->>'actor' IS DISTINCT FROM 'ann@acme.example.test'
       OR v_body->'items'->0->'actor_is_agent' IS DISTINCT FROM 'false'::jsonb
       OR v_body->'items'->1->>'event' IS DISTINCT FROM 'submitted' OR v_body->'items'->1->>'file_name' IS DISTINCT FROM 'prices.xlsx' THEN
        RAISE EXCEPTION 'TEST FAILED: GET /patch-events for Uma: want approved then submitted, her patch only, got %', v_body;
    END IF;

    -- Another organization and a member without patch permissions see none of it.
    v_r := api.rest_invoke('GET', '/patches/' || v_patch || '/lines', v_gil, NULL::bytea);
    IF (v_r).status_code IS DISTINCT FROM 404 OR api.content_json((v_r).content)->>'code' IS DISTINCT FROM 'core.patch.not_found' THEN
        RAISE EXCEPTION 'TEST FAILED: another organization''s patch must be 404, got %', (v_r).status_code;
    END IF;
    v_body := api.content_json((api.rest_invoke('GET', '/patches/pending', v_gil, NULL::bytea)).content);
    IF (v_body->>'total')::int IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'TEST FAILED: Gil''s organization has no pending patch, got %', v_body;
    END IF;
    v_r := api.rest_invoke('POST', '/patches/' || v_own || '/approve', v_gil, '{}'::jsonb);
    IF (v_r).status_code IS DISTINCT FROM 404 THEN
        RAISE EXCEPTION 'TEST FAILED: approving another organization''s patch must be 404, got %', (v_r).status_code;
    END IF;
    v_body := api.content_json((api.rest_invoke('GET', '/patch-events', v_bob, NULL::bytea)).content);
    IF (v_body->>'total')::int IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'TEST FAILED: Bob may see no patch, got %', v_body;
    END IF;

    -- RPC: submit, a submitter's decision refused, the approver rejects.
    v_r := api.rpc_invoke(api.rpc_resolve('patch.submit'), v_uma, convert_to(jsonb_build_object(
        'jsonrpc', '2.0', 'id', 7, 'method', 'patch.submit',
        'params', jsonb_build_object('file_name', 'rpc.xlsx', 'lines', v_next))::text, 'UTF8'));
    v_body := api.content_json((v_r).content);
    v_rpc := (v_body->'result'->>'patch_id')::uuid;
    IF (v_r).status_code IS DISTINCT FROM 200 OR v_body->'result'->>'state' IS DISTINCT FROM 'pending' OR v_body->'id' IS DISTINCT FROM '7'::jsonb THEN
        RAISE EXCEPTION 'TEST FAILED: RPC patch.submit: want a pending patch, got % %', (v_r).status_code, v_body;
    END IF;
    v_r := api.rpc_invoke(api.rpc_resolve('patch.reject'), v_uma, convert_to(jsonb_build_object(
        'jsonrpc', '2.0', 'id', 8, 'method', 'patch.reject', 'params', jsonb_build_object('patchId', v_rpc))::text, 'UTF8'));
    IF (v_r).status_code IS DISTINCT FROM 403 THEN
        RAISE EXCEPTION 'TEST FAILED: RPC patch.reject by a submitter must be 403, got % %', (v_r).status_code, api.content_json((v_r).content);
    END IF;
    v_r := api.rpc_invoke(api.rpc_resolve('patch.approve'), v_ann, convert_to(jsonb_build_object(
        'jsonrpc', '2.0', 'id', 9, 'method', 'patch.approve', 'params', jsonb_build_object('patchId', v_own))::text, 'UTF8'));
    v_body := api.content_json((v_r).content);
    IF (v_r).status_code IS DISTINCT FROM 409 OR v_body->'error'->'data'->>'code' IS DISTINCT FROM 'core.patch.own_patch' THEN
        RAISE EXCEPTION 'TEST FAILED: RPC patch.approve of one''s own patch: want -32010 core.patch.own_patch, got % %', (v_r).status_code, v_body;
    END IF;
    v_r := api.rpc_invoke(api.rpc_resolve('patch.reject'), v_ann, convert_to(jsonb_build_object(
        'jsonrpc', '2.0', 'id', 10, 'method', 'patch.reject', 'params', jsonb_build_object('patchId', v_rpc, 'note', 'no'))::text, 'UTF8'));
    v_body := api.content_json((v_r).content);
    IF (v_r).status_code IS DISTINCT FROM 200 OR v_body->'result'->>'state' IS DISTINCT FROM 'rejected' THEN
        RAISE EXCEPTION 'TEST FAILED: RPC patch.reject by Ann: want rejected, got % %', (v_r).status_code, v_body;
    END IF;
    v_r := api.rpc_invoke(api.rpc_resolve('patch.lines'), v_gil, convert_to(jsonb_build_object(
        'jsonrpc', '2.0', 'id', 11, 'method', 'patch.lines', 'params', jsonb_build_object('patchId', v_rpc))::text, 'UTF8'));
    v_body := api.content_json((v_r).content);
    IF (v_r).status_code IS DISTINCT FROM 422 OR v_body->'error'->'data'->'invalid-params' IS DISTINCT FROM '[{"name": "patchId", "reason": "not_found"}]'::jsonb THEN
        RAISE EXCEPTION 'TEST FAILED: RPC patch.lines of another organization''s patch: want -32011 not_found, got % %', (v_r).status_code, v_body;
    END IF;

    -- MCP, through an agent connection. A connection's agent.* role must fit
    -- inside its person's permissions; of the shipped roles only an owner's or
    -- admin's (agent.delegate) carries patch.*, so Alice's agent is the caller.
    PERFORM pg_temp.test_act_as(NULL);
    v_mcp := pg_temp.test_mcp_context(current_setting('test.alice_subject'), v_acme);
    IF NOT v_mcp ? 'connection' THEN
        RAISE EXCEPTION 'TEST FAILED: Alice needs an MCP connection, got %', v_mcp;
    END IF;
    v_env := (api.mcp_call_tool('submit_patch', jsonb_build_object('file_name', 'agent.xlsx', 'lines', v_next),
                                v_mcp, '"m1"'::jsonb)).envelope;
    v_patch := (v_env->'result'->'structuredContent'->'patch'->>'patch_id')::uuid;
    IF v_env->'result'->'isError' IS DISTINCT FROM 'false'::jsonb
       OR v_env->'result'->'structuredContent'->'patch'->>'state' IS DISTINCT FROM 'pending'
       OR v_env->'result'->'structuredContent'->'nextActions'->0->>'tool' IS DISTINCT FROM 'read_patch_lines' THEN
        RAISE EXCEPTION 'TEST FAILED: MCP submit_patch: want a pending patch and read_patch_lines next, got %', v_env;
    END IF;
    v_env := (api.mcp_call_tool('list_pending_patches', '{}'::jsonb, v_mcp, '"m2"'::jsonb)).envelope;
    IF v_env->'result'->'isError' IS DISTINCT FROM 'false'::jsonb
       OR (v_env->'result'->'structuredContent'->>'total')::int IS DISTINCT FROM 2
       OR (v_env->'result'->'structuredContent'->'items'->0->>'patch_id')::uuid IS DISTINCT FROM v_own THEN
        RAISE EXCEPTION 'TEST FAILED: MCP list_pending_patches: want Ann''s patch, then the agent''s, got %', v_env;
    END IF;
    v_env := (api.mcp_call_tool('approve_patch', jsonb_build_object('patchId', v_patch), v_mcp, '"m3"'::jsonb)).envelope;
    IF v_env->'result'->'isError' IS DISTINCT FROM 'true'::jsonb
       OR (v_env->'result'->'content'->0->>'text')::jsonb->>'code' IS DISTINCT FROM 'core.patch.own_patch' THEN
        RAISE EXCEPTION 'TEST FAILED: MCP approve_patch of its person''s own patch: want isError core.patch.own_patch, got %', v_env;
    END IF;
    v_env := (api.mcp_call_tool('read_patch_lines', jsonb_build_object('patchId', 'nope'), v_mcp, '"m4"'::jsonb)).envelope;
    IF v_env->'result'->'isError' IS DISTINCT FROM 'true'::jsonb
       OR (v_env->'result'->'content'->0->>'text')::jsonb->'invalidParams' IS DISTINCT FROM '[{"name": "patchId", "reason": "invalid"}]'::jsonb THEN
        RAISE EXCEPTION 'TEST FAILED: MCP read_patch_lines with a malformed id: want isError naming patchId, got %', v_env;
    END IF;
    v_env := (api.mcp_call_tool('reject_patch', jsonb_build_object('patchId', v_own, 'note', 'not now'), v_mcp, '"m5"'::jsonb)).envelope;
    IF v_env->'result'->'isError' IS DISTINCT FROM 'false'::jsonb
       OR v_env->'result'->'structuredContent'->'patch'->>'state' IS DISTINCT FROM 'rejected' THEN
        RAISE EXCEPTION 'TEST FAILED: MCP reject_patch of Ann''s patch: want rejected, got %', v_env;
    END IF;
    v_env := (api.mcp_call_tool('patch_desk_whoami', '{}'::jsonb, NULL, '"m6"'::jsonb)).envelope;
    IF (v_env->'error'->>'code')::int IS DISTINCT FROM -32602 THEN
        RAISE EXCEPTION 'TEST FAILED: MCP patch_desk_whoami anonymous: want -32602, got %', v_env;
    END IF;

    PERFORM pg_temp.test_act_as(NULL);
    RAISE NOTICE '  + patch desk: submit, check, lists, approve and reject over REST, RPC and MCP; refusals coded; other organizations see nothing';
END $$;
