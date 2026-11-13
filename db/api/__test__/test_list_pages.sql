-- Proves: list routes page by limit and offset, keep the total past the end, and refuse a bad limit or offset.
-- ============================================================================
-- Test: the organization's lists are paged: limit, offset, and the page envelope
-- ============================================================================
-- Alice owns Acme Corp (fixture). The checks run on GET /agents and
-- GET /connections, which share api.page_query_schema() with the patch desk's
-- lists.
-- ============================================================================

DO $$
DECLARE
    v_acme  uuid := current_setting('test.acme_org_id')::uuid;
    v_alice extensions.hstore := pg_temp.test_session_headers(current_setting('test.alice_subject'), v_acme);
    v_page  jsonb;
BEGIN
    IF pg_temp.expect_status('GET /connections?offset=2147483648', api.rest_invoke('GET', '/connections?offset=2147483648', v_alice, NULL::bytea), 400)
           ->>'code' IS DISTINCT FROM 'pgmi.invalid_query' THEN
        RAISE EXCEPTION 'TEST FAILED: an offset past int4 must be 400 pgmi.invalid_query, never the first page';
    END IF;
    v_page := pg_temp.expect_status('GET /agents?limit=1', api.rest_invoke('GET', '/agents?limit=1', v_alice, NULL::bytea), 200);
    IF v_page->'agentsEnabled' IS DISTINCT FROM 'true'::jsonb OR (v_page ?& ARRAY['items', 'total', 'limit', 'offset', 'hasMore']) IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST FAILED: GET /agents answers a page envelope with agentsEnabled, got %', v_page;
    END IF;
    v_page := pg_temp.expect_status('GET /connections?offset=5', api.rest_invoke('GET', '/connections?offset=5', v_alice, NULL::bytea), 200);
    IF v_page->'items' IS DISTINCT FROM '[]'::jsonb OR (v_page->>'offset')::int IS DISTINCT FROM 5
       OR v_page->'total' IS DISTINCT FROM pg_temp.expect_status('GET /connections',
              api.rest_invoke('GET', '/connections', v_alice, NULL::bytea), 200)->'total' THEN
        RAISE EXCEPTION 'TEST FAILED: GET /connections pages by offset and keeps the total past the end, got %', v_page;
    END IF;
    PERFORM pg_temp.expect_status('GET /connections?limit=x', api.rest_invoke('GET', '/connections?limit=x', v_alice, NULL::bytea), 400);
    RAISE NOTICE '  + list routes: page envelope, offset past the end, bad limit and offset refused';
END $$;
