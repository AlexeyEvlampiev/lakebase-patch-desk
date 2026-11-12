-- Proves: a mapped database login acts as its own person, whatever a setting, an MCP context or a session handle claims.
-- ============================================================================
-- Test: a mapped login acts as its principal, whatever it states
-- ============================================================================
-- The mapping rules of membership.fn_map_database_login, then the deploy
-- login itself (session_user) mapped to Bob: a trusted context naming Alice,
-- an MCP context naming Alice and Alice's real login session over REST all
-- still act as Bob. Needs no switch of login, so it runs on every deploy,
-- Lakebase included.
-- ============================================================================

DO $$
DECLARE
    v_role    text := current_user;
    v_stand_in text := pg_temp.deployment_setting('database_caller_role');
    v_acme    uuid := current_setting('test.acme_org_id')::uuid;
    v_alice   uuid := pg_temp.test_person(current_setting('test.alice_subject'));
    v_bob     uuid := pg_temp.test_person(current_setting('test.bob_subject'));
    v_login   membership.database_login;
    v_other   membership.database_login;
    v_mcp     jsonb;
    v_rest    api.http_response;
    v_rpc     api.http_response;
    v_body    jsonb;
    v_mapped  bigint;
BEGIN
    RAISE DEBUG '-> Database logins: the deploy login mapped to Bob';
    PERFORM pg_temp.test_act_as(NULL);

    -- The mapping rules, as the kernel outside a request. Any existing role
    -- will do as the login here; the caller role is one. A deployed
    -- database may hold mappings already (the demo's provisioning).
    PERFORM pg_temp.test_as_kernel();
    v_mapped := (SELECT count(*) FROM membership.database_login);
    IF (membership.fn_map_database_login('no-such-login-dl', v_alice, v_acme)).database_role IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: a role that does not exist must not be mapped';
    END IF;
    IF (membership.fn_map_database_login(v_stand_in, v_bob,
            (membership.fn_create_organization_with_owner('Elsewhere', 'dl-elsewhere', v_alice)).object_id)).database_role IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: a login must not be mapped into an organization its principal is not a member of';
    END IF;
    v_login := membership.fn_map_database_login(v_stand_in, v_alice, v_acme);
    IF v_login.database_role IS DISTINCT FROM v_stand_in OR v_login.principal_object_id IS DISTINCT FROM v_alice THEN
        RAISE EXCEPTION 'TEST FAILED: the stand-in login must map to Alice, got %', row_to_json(v_login);
    END IF;
    v_other := membership.fn_map_database_login(v_stand_in, v_alice, v_acme);
    IF v_other.mapped_at IS DISTINCT FROM v_login.mapped_at THEN
        RAISE EXCEPTION 'TEST FAILED: mapping the same pair again must return the existing row, got % then %', row_to_json(v_login), row_to_json(v_other);
    END IF;
    IF (membership.fn_map_database_login(v_stand_in, v_bob, v_acme)).database_role IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: a mapped login must not be mapped to a second principal';
    END IF;
    IF (membership.fn_map_database_login(session_user, v_alice, v_acme)).database_role IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: a principal must not get a second login';
    END IF;
    v_login := membership.fn_map_database_login(session_user, v_bob, v_acme);
    IF v_login.database_role IS DISTINCT FROM session_user OR v_login.principal_object_id IS DISTINCT FROM v_bob THEN
        RAISE EXCEPTION 'TEST FAILED: the deploy login must map to Bob, got %', row_to_json(v_login);
    END IF;
    -- From now on every call of this session acts as Bob, a request of a
    -- person who is not a platform operator: no more mappings.
    IF (membership.fn_map_database_login(v_stand_in, v_alice, v_acme)).database_role IS DISTINCT FROM NULL
       OR (SELECT count(*) FROM membership.database_login) IS DISTINCT FROM v_mapped + 2 THEN
        RAISE EXCEPTION 'TEST FAILED: a mapped login must not write a mapping';
    END IF;
    EXECUTE format('SET ROLE %I', v_role);

    -- A trusted context naming Alice; the login is Bob's.
    PERFORM pg_temp.test_act_as(current_setting('test.alice_subject'), v_acme);
    IF api.current_principal_id() IS DISTINCT FROM v_bob OR api.current_actor_kind() IS DISTINCT FROM 'human'
       OR api.current_organization_id() IS DISTINCT FROM v_acme THEN
        RAISE EXCEPTION 'TEST FAILED: a mapped login stating Alice must still be Bob, got principal % (%), organization %',
            api.current_principal_id(), api.current_actor_kind(), api.current_organization_id();
    END IF;

    v_mcp := (api.mcp_handle_request(jsonb_build_object('jsonrpc', '2.0', 'id', 1, 'method', 'tools/call',
                  'params', jsonb_build_object('name', 'dl_whoami', 'arguments', '{}'::jsonb)),
              jsonb_build_object('principalId', v_alice, 'connection', 'not-a-handle'))).envelope;
    v_rest := api.rest_invoke('GET', '/dl/whoami', pg_temp.test_session_headers(current_setting('test.alice_subject'), v_acme), NULL::bytea);
    v_rpc := api.rpc_invoke(api.rpc_resolve('dl.whoami'), ''::extensions.hstore,
                            convert_to('{"jsonrpc":"2.0","id":1,"method":"dl.whoami","params":{}}', 'UTF8'));
    PERFORM pg_temp.test_act_as(NULL);

    IF (v_mcp #>> '{result,structuredContent,principalId}')::uuid IS DISTINCT FROM v_bob THEN
        RAISE EXCEPTION 'TEST FAILED: MCP as the mapped login must answer Bob, got %', v_mcp;
    END IF;
    v_body := api.content_json(v_rest.content);
    IF v_rest.status_code IS DISTINCT FROM 200 OR (v_body->>'principalId')::uuid IS DISTINCT FROM v_bob THEN
        RAISE EXCEPTION 'TEST FAILED: REST with Alice''s own session as the mapped login must answer Bob, got % %', v_rest.status_code, v_body;
    END IF;
    v_body := api.content_json(v_rpc.content);
    IF v_rpc.status_code IS DISTINCT FROM 200 OR (v_body #>> '{result,principalId}')::uuid IS DISTINCT FROM v_bob THEN
        RAISE EXCEPTION 'TEST FAILED: RPC as the mapped login must answer Bob, got % %', v_rpc.status_code, v_body;
    END IF;
END $$;
