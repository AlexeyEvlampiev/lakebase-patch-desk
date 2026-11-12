-- ============================================================================
-- Fixture: database logins (membership.database_login)
-- ============================================================================
-- A probe for the tests of this directory: one read, who the request acts
-- as, exposed as MCP tool dl_whoami, REST GET /dl/whoami and RPC dl.whoami.
-- Created inside the test run and rolled back with it, never deployed.
-- Uses the API fixture: Alice owns Acme Corp, Bob is a member.
-- ============================================================================

-- One read, exposed three ways: who the request acts as.
CREATE FUNCTION api.dl_whoami() RETURNS jsonb LANGUAGE sql STABLE AS $w$
    SELECT jsonb_build_object(
        'sessionUser', session_user::text,
        'principalId', api.current_principal_id(),
        'actorKind', api.current_actor_kind(),
        'organizationId', api.current_organization_id());
$w$;

DO $$
BEGIN
    PERFORM api.create_or_replace_mcp_handler(jsonb_build_object(
        'id', 'ffffffff-d100-4000-8000-000000000001', 'type', 'tool', 'effect', 'read', 'name', 'dl_whoami',
        'description', 'Who the request acts as', 'access', 'authenticated'),
        $b$BEGIN
            RETURN api.mcp_tool_result(jsonb_build_array(api.mcp_text('whoami')), (request).request_id,
                structured_content => api.dl_whoami());
        END;$b$);
    PERFORM api.create_or_replace_rest_handler(jsonb_build_object(
        'id', 'ffffffff-d100-4000-8000-000000000002', 'path', '/dl/whoami', 'httpMethod', '^GET$',
        'name', 'dl_whoami_rest', 'description', 'Who the request acts as', 'access', 'authenticated'),
        $b$BEGIN
            RETURN api.json_response(200, api.dl_whoami());
        END;$b$);
    PERFORM api.create_or_replace_rpc_handler(jsonb_build_object(
        'id', 'ffffffff-d100-4000-8000-000000000003', 'methodName', 'dl.whoami',
        'description', 'Who the request acts as', 'access', 'authenticated'),
        $b$BEGIN
            RETURN api.jsonrpc_success(api.dl_whoami(), api.content_json((request).content)->'id');
        END;$b$);
END $$;
