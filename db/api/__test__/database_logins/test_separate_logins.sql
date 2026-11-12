-- Proves: separate database logins call the tool, the route and the method as themselves, and nothing in a request lets one act as another.
-- ============================================================================
-- Test: separate database logins (superuser deploys only)
-- ============================================================================
-- Alice's login and an agent's login, each mapped, call the tool, the route
-- and the method as themselves; an unmapped login in the caller role is
-- refused, one without it cannot call at all; settings, MCP context keys and
-- session handles naming someone else count for nothing, even for a mapped
-- login in the api role. Switching login (SET SESSION AUTHORIZATION) needs a
-- superuser, so this runs only when the deploy login is one (the last run of
-- db/local-check.sh) and is skipped otherwise, as on Lakebase.
-- ============================================================================

DO $$
DECLARE
    v_role    text := current_user;
    v_caller  text := pg_temp.deployment_setting('database_caller_role');
    v_api     text := pg_temp.deployment_setting('database_api_role');
    v_acme    uuid := current_setting('test.acme_org_id')::uuid;
    v_alice   uuid := pg_temp.test_person(current_setting('test.alice_subject'));
    v_bob     uuid := pg_temp.test_person(current_setting('test.bob_subject'));
    v_agent   uuid;
    v_bob_session extensions.hstore;
    v_call    jsonb := '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"dl_whoami","arguments":{}}}';
    v_rpc_body bytea := convert_to('{"jsonrpc":"2.0","id":1,"method":"dl.whoami","params":{}}', 'UTF8');
    v_mcp     jsonb;
    v_rest    api.http_response;
    v_rpc     api.http_response;
    v_state   text;
BEGIN
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = session_user) THEN
        RAISE NOTICE 'skipped: separate logins need a superuser deploy (SET SESSION AUTHORIZATION)';
        RETURN;
    END IF;
    RAISE DEBUG '-> Database logins: separate logins';
    PERFORM pg_temp.test_act_as(NULL);

    RESET ROLE;
    CREATE ROLE "dl-alice@example.com" LOGIN;
    CREATE ROLE "dl-agent-app-id" LOGIN;
    CREATE ROLE "dl-mallory@example.com" LOGIN;
    CREATE ROLE "dl-nobody@example.com" LOGIN;
    EXECUTE format('GRANT %I TO "dl-alice@example.com", "dl-agent-app-id", "dl-mallory@example.com"', v_caller);
    EXECUTE format('SET ROLE %I', v_role);

    PERFORM pg_temp.test_as_kernel();
    v_agent := (membership.fn_register_service_principal('dl.agent', 'Test agent', 'dl-agent-app-id')).principal_object_id;
    PERFORM membership.fn_add_member(v_acme, v_agent, 'org.member');
    IF (membership.fn_map_database_login('dl-alice@example.com', v_alice, v_acme)).database_role IS NULL
       OR (membership.fn_map_database_login('dl-agent-app-id', v_agent, v_acme)).database_role IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED: Alice''s and the agent''s logins must map';
    END IF;
    EXECUTE format('SET ROLE %I', v_role);
    -- A real login session for Bob, opened by the deploy (a gateway).
    v_bob_session := pg_temp.test_session_headers(current_setting('test.bob_subject'), v_acme);

    -- 1. A mapped login calls the tool, the route and the method as itself.
    RESET ROLE;
    SET SESSION AUTHORIZATION "dl-alice@example.com";
    v_mcp := (api.mcp_handle_request(v_call, '{}'::jsonb)).envelope;
    v_rest := api.rest_invoke('GET', '/dl/whoami', ''::extensions.hstore, NULL::bytea);
    v_rpc := api.rpc_invoke(api.rpc_resolve('dl.whoami'), ''::extensions.hstore, v_rpc_body);
    RESET SESSION AUTHORIZATION;
    IF (v_mcp #>> '{result,structuredContent,principalId}')::uuid IS DISTINCT FROM v_alice
       OR v_mcp #>> '{result,structuredContent,actorKind}' IS DISTINCT FROM 'human'
       OR v_mcp #>> '{result,structuredContent,sessionUser}' IS DISTINCT FROM 'dl-alice@example.com' THEN
        RAISE EXCEPTION 'TEST FAILED: Alice''s login over MCP must be Alice, a human, got %', v_mcp;
    END IF;
    IF v_rest.status_code IS DISTINCT FROM 200
       OR (api.content_json(v_rest.content)->>'principalId')::uuid IS DISTINCT FROM v_alice THEN
        RAISE EXCEPTION 'TEST FAILED: Alice''s login over REST must be Alice, got % %', v_rest.status_code, api.content_json(v_rest.content);
    END IF;
    IF v_rpc.status_code IS DISTINCT FROM 200
       OR (api.content_json(v_rpc.content) #>> '{result,principalId}')::uuid IS DISTINCT FROM v_alice THEN
        RAISE EXCEPTION 'TEST FAILED: Alice''s login over RPC must be Alice, got % %', v_rpc.status_code, api.content_json(v_rpc.content);
    END IF;

    SET SESSION AUTHORIZATION "dl-agent-app-id";
    v_mcp := (api.mcp_handle_request(v_call, '{}'::jsonb)).envelope;
    RESET SESSION AUTHORIZATION;
    IF (v_mcp #>> '{result,structuredContent,principalId}')::uuid IS DISTINCT FROM v_agent
       OR v_mcp #>> '{result,structuredContent,actorKind}' IS DISTINCT FROM 'service' THEN
        RAISE EXCEPTION 'TEST FAILED: the agent''s login over MCP must be the agent, a service, got %', v_mcp;
    END IF;

    -- 2. An unmapped login is refused; without the caller role it cannot call at all.
    SET SESSION AUTHORIZATION "dl-mallory@example.com";
    v_mcp := (api.mcp_handle_request(v_call, '{}'::jsonb)).envelope;
    v_rest := api.rest_invoke('GET', '/dl/whoami', ''::extensions.hstore, NULL::bytea);
    RESET SESSION AUTHORIZATION;
    IF v_mcp ? 'result' OR (v_mcp #>> '{error,code}')::int IS DISTINCT FROM -32602 THEN
        RAISE EXCEPTION 'TEST FAILED: an unmapped login over MCP must be refused with -32602, got %', v_mcp;
    END IF;
    IF v_rest.status_code IS DISTINCT FROM 401 THEN
        RAISE EXCEPTION 'TEST FAILED: an unmapped login over REST must get 401, got %', v_rest.status_code;
    END IF;
    SET SESSION AUTHORIZATION "dl-nobody@example.com";
    BEGIN
        PERFORM api.mcp_handle_request(v_call, '{}'::jsonb);
    EXCEPTION WHEN insufficient_privilege THEN
        v_state := SQLSTATE;
    END;
    RESET SESSION AUTHORIZATION;
    IF v_state IS DISTINCT FROM '42501' THEN
        RAISE EXCEPTION 'TEST FAILED: a login without the caller role must be denied (42501), got %', coalesce(v_state, 'success');
    END IF;

    -- 3. Settings and handles naming someone else count for nothing.
    SET SESSION AUTHORIZATION "dl-alice@example.com";
    PERFORM set_config('auth.principal_id', v_bob::text, true), set_config('auth.actual_principal_id', v_bob::text, true);
    v_mcp := (api.mcp_handle_request(v_call, jsonb_build_object('principalId', v_bob, 'connection', 'not-a-handle'))).envelope;
    v_rest := api.rest_invoke('GET', '/dl/whoami', extensions.hstore('x-login-session', 'forged'), NULL::bytea);
    RESET SESSION AUTHORIZATION;
    IF (v_mcp #>> '{result,structuredContent,principalId}')::uuid IS DISTINCT FROM v_alice THEN
        RAISE EXCEPTION 'TEST FAILED: Alice stating Bob over MCP must still be Alice, got %', v_mcp;
    END IF;
    IF v_rest.status_code IS DISTINCT FROM 200
       OR (api.content_json(v_rest.content)->>'principalId')::uuid IS DISTINCT FROM v_alice THEN
        RAISE EXCEPTION 'TEST FAILED: Alice with a forged session handle must still be Alice, got % %', v_rest.status_code, api.content_json(v_rest.content);
    END IF;

    -- Even a mapped login in the api role (a gateway) acts only as itself.
    EXECUTE format('GRANT %I TO "dl-alice@example.com"', v_api);
    SET SESSION AUTHORIZATION "dl-alice@example.com";
    PERFORM set_config('auth.principal_id', v_bob::text, true);
    v_mcp := (api.mcp_handle_request(v_call, '{}'::jsonb)).envelope;
    v_rest := api.rest_invoke('GET', '/dl/whoami', v_bob_session, NULL::bytea);
    RESET SESSION AUTHORIZATION;
    IF (v_mcp #>> '{result,structuredContent,principalId}')::uuid IS DISTINCT FROM v_alice THEN
        RAISE EXCEPTION 'TEST FAILED: Alice in the api role stating Bob must still be Alice, got %', v_mcp;
    END IF;
    IF v_rest.status_code IS DISTINCT FROM 200
       OR (api.content_json(v_rest.content)->>'principalId')::uuid IS DISTINCT FROM v_alice THEN
        RAISE EXCEPTION 'TEST FAILED: Alice in the api role with Bob''s real session must still be Alice, got % %', v_rest.status_code, api.content_json(v_rest.content);
    END IF;

    SET SESSION AUTHORIZATION "dl-mallory@example.com";
    PERFORM set_config('auth.principal_id', v_bob::text, true);
    v_mcp := (api.mcp_handle_request(v_call, '{}'::jsonb)).envelope;
    RESET SESSION AUTHORIZATION;
    IF v_mcp ? 'result' THEN
        RAISE EXCEPTION 'TEST FAILED: an unmapped login stating Bob must be refused, got %', v_mcp;
    END IF;

    EXECUTE format('SET ROLE %I', v_role);
    PERFORM pg_temp.test_act_as(NULL);
END $$;
