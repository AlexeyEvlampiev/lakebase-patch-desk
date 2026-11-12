-- Proves: an uploader and an approver, each on their own database login, use the patch desk as themselves; an unmapped login is refused.
-- ============================================================================
-- Test: the patch desk with separate database logins (superuser deploys only)
-- ============================================================================
-- An uploader's and an approver's own logins, each mapped, submit, list and
-- decide over REST, RPC and MCP as themselves, with no session handle; an
-- unmapped login is refused; a forged auth.principal_id and another person's
-- real session handle count for nothing. Switching login (SET SESSION
-- AUTHORIZATION) needs a superuser, so this runs only when the deploy login
-- is one (the last run of db/local-check.sh) and is skipped otherwise.
-- ============================================================================

DO $$
DECLARE
    v_role    text := current_user;
    v_caller  text := pg_temp.deployment_setting('database_caller_role');
    v_acme    uuid := current_setting('test.acme_org_id')::uuid;
    v_uma     uuid;
    v_ann     uuid;
    v_ann_session extensions.hstore;
    v_lines   jsonb := '[{"line_no": 1, "product_code": "T-DL-1", "field": "unit_price", "new_value": "4.20", "reason": "price list"}]';
    v_r       api.http_response;
    v_me      api.http_response;
    v_body    jsonb;
    v_mcp     jsonb;
    v_patch   uuid;
BEGIN
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = session_user) THEN
        RAISE NOTICE 'skipped: patch desk logins need a superuser deploy (SET SESSION AUTHORIZATION)';
        RETURN;
    END IF;
    RAISE DEBUG '-> Database logins: the patch desk';
    PERFORM pg_temp.test_act_as(NULL);
    PERFORM core.fn_add_product('T-DL-1', 'Login test water', 'BEV', 4.00);

    RESET ROLE;
    CREATE ROLE "pd-uma@example.com" LOGIN;
    CREATE ROLE "pd-ann@example.com" LOGIN;
    CREATE ROLE "pd-mallory@example.com" LOGIN;
    EXECUTE format('GRANT %I TO "pd-uma@example.com", "pd-ann@example.com", "pd-mallory@example.com"', v_caller);
    EXECUTE format('SET ROLE %I', v_role);

    v_uma := pg_temp.test_login('google', 'pd-login-uma', 'pd-uma@example.com', 'Uma', true);
    v_ann := pg_temp.test_login('google', 'pd-login-ann', 'pd-ann@example.com', 'Ann', true);
    PERFORM membership.fn_add_member(v_acme, v_uma, 'patch.uploader');
    PERFORM membership.fn_add_member(v_acme, v_ann, 'patch.approver');
    v_ann_session := pg_temp.test_session_headers('google|pd-login-ann', v_acme);
    PERFORM pg_temp.test_as_kernel();
    IF (membership.fn_map_database_login('pd-uma@example.com', v_uma, v_acme)).database_role IS NULL
       OR (membership.fn_map_database_login('pd-ann@example.com', v_ann, v_acme)).database_role IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: Uma''s and Ann''s logins must map';
    END IF;
    EXECUTE format('SET ROLE %I', v_role);
    PERFORM pg_temp.test_act_as(NULL);

    -- 1. Uma's login submits over REST and lists over RPC and MCP, as Uma.
    RESET ROLE;
    SET SESSION AUTHORIZATION "pd-uma@example.com";
    v_r := api.rest_invoke('POST', '/patches', ''::extensions.hstore,
                           jsonb_build_object('file_name', 'login.xlsx', 'lines', v_lines));
    RESET SESSION AUTHORIZATION;
    v_body := api.content_json((v_r).content);
    v_patch := (v_body->>'patch_id')::uuid;
    IF (v_r).status_code IS DISTINCT FROM 201 OR v_body->>'submitted_by' IS DISTINCT FROM 'pd-uma@example.com'
       OR v_body->>'state' IS DISTINCT FROM 'pending' THEN
        RAISE EXCEPTION 'TEST FAILED: Uma''s login submitting over REST: want 201 pending by Uma, got % %', (v_r).status_code, v_body;
    END IF;

    SET SESSION AUTHORIZATION "pd-uma@example.com";
    v_r := api.rpc_invoke(api.rpc_resolve('patch.list_mine'), ''::extensions.hstore,
                          convert_to('{"jsonrpc":"2.0","id":1,"method":"patch.list_mine","params":{}}', 'UTF8'));
    v_mcp := (api.mcp_handle_request(jsonb_build_object('jsonrpc', '2.0', 'id', 2, 'method', 'tools/call',
                  'params', jsonb_build_object('name', 'list_my_patches', 'arguments', '{}'::jsonb)), '{}'::jsonb)).envelope;
    RESET SESSION AUTHORIZATION;
    v_body := api.content_json((v_r).content);
    IF (v_r).status_code IS DISTINCT FROM 200 OR (v_body #>> '{result,total}')::int IS DISTINCT FROM 1
       OR (v_body #>> '{result,items,0,patch_id}')::uuid IS DISTINCT FROM v_patch THEN
        RAISE EXCEPTION 'TEST FAILED: Uma''s login listing over RPC: want her one patch, got % %', (v_r).status_code, v_body;
    END IF;
    IF (v_mcp #>> '{result,structuredContent,items,0,patch_id}')::uuid IS DISTINCT FROM v_patch THEN
        RAISE EXCEPTION 'TEST FAILED: Uma''s login listing over MCP: want her one patch, got %', v_mcp;
    END IF;

    -- 2. Settings and handles naming Ann count for nothing: Uma stays Uma,
    --    who may not decide.
    SET SESSION AUTHORIZATION "pd-uma@example.com";
    PERFORM set_config('auth.principal_id', v_ann::text, true), set_config('auth.actual_principal_id', v_ann::text, true);
    v_r := api.rest_invoke('POST', '/patches/' || v_patch || '/approve', v_ann_session, '{}'::jsonb);
    v_me := api.rest_invoke('GET', '/patch-desk/me', v_ann_session, NULL::bytea);
    RESET SESSION AUTHORIZATION;
    v_body := api.content_json((v_me).content);
    IF (v_r).status_code IS DISTINCT FROM 403 OR api.content_json((v_r).content)->>'code' IS DISTINCT FROM 'pgmi.forbidden' THEN
        RAISE EXCEPTION 'TEST FAILED: Uma''s login with Ann''s session approving: want 403 pgmi.forbidden, got % %',
            (v_r).status_code, api.content_json((v_r).content);
    END IF;
    IF (v_body->>'principal_id')::uuid IS DISTINCT FROM v_uma OR v_body->'can_decide' IS DISTINCT FROM 'false'::jsonb THEN
        RAISE EXCEPTION 'TEST FAILED: Uma''s login stating Ann must still be Uma, got %', v_body;
    END IF;

    -- 3. Ann's login approves over REST and lists the history over MCP, as Ann.
    SET SESSION AUTHORIZATION "pd-ann@example.com";
    v_r := api.rest_invoke('POST', '/patches/' || v_patch || '/approve', ''::extensions.hstore, '{"note": "fine"}'::jsonb);
    v_mcp := (api.mcp_handle_request(jsonb_build_object('jsonrpc', '2.0', 'id', 3, 'method', 'tools/call',
                  'params', jsonb_build_object('name', 'read_patch_history', 'arguments', '{}'::jsonb)), '{}'::jsonb)).envelope;
    RESET SESSION AUTHORIZATION;
    v_body := api.content_json((v_r).content);
    IF (v_r).status_code IS DISTINCT FROM 200 OR v_body->>'state' IS DISTINCT FROM 'approved'
       OR v_body->>'decided_by' IS DISTINCT FROM 'pd-ann@example.com' THEN
        RAISE EXCEPTION 'TEST FAILED: Ann''s login approving over REST: want 200 approved by Ann, got % %', (v_r).status_code, v_body;
    END IF;
    IF v_mcp #>> '{result,structuredContent,items,0,event}' IS DISTINCT FROM 'approved'
       OR v_mcp #>> '{result,structuredContent,items,0,actor}' IS DISTINCT FROM 'pd-ann@example.com' THEN
        RAISE EXCEPTION 'TEST FAILED: Ann''s login reading the history over MCP: want her approval first, got %', v_mcp;
    END IF;

    -- 4. An unmapped login is refused.
    SET SESSION AUTHORIZATION "pd-mallory@example.com";
    v_r := api.rest_invoke('POST', '/patches', ''::extensions.hstore,
                           jsonb_build_object('file_name', 'mallory.xlsx', 'lines', v_lines));
    v_mcp := (api.mcp_handle_request(jsonb_build_object('jsonrpc', '2.0', 'id', 4, 'method', 'tools/call',
                  'params', jsonb_build_object('name', 'submit_patch',
                                               'arguments', jsonb_build_object('file_name', 'm.xlsx', 'lines', v_lines))), '{}'::jsonb)).envelope;
    RESET SESSION AUTHORIZATION;
    IF (v_r).status_code IS DISTINCT FROM 401 THEN
        RAISE EXCEPTION 'TEST FAILED: an unmapped login submitting over REST must get 401, got %', (v_r).status_code;
    END IF;
    IF v_mcp ? 'result' OR (v_mcp #>> '{error,code}')::int IS DISTINCT FROM -32602 THEN
        RAISE EXCEPTION 'TEST FAILED: an unmapped login submitting over MCP must get -32602, got %', v_mcp;
    END IF;

    EXECUTE format('SET ROLE %I', v_role);
    PERFORM pg_temp.test_act_as(NULL);
    RAISE NOTICE '  + patch desk logins: Uma''s and Ann''s own logins submit, list and decide as themselves; forged identity ignored; unmapped refused';
END $$;
