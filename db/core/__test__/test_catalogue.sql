-- Proves: the demo catalogue is seeded on every deploy, a price must be positive, and an approved fix survives the next deploy.
-- ============================================================================
-- Test: the catalogue seed, its product rules, and a redeploy keeping fixes
-- ============================================================================
-- The seed runs on every deploy in every environment. Prices are not
-- asserted: on a kept database an approved patch may have changed them.

DO $$
DECLARE
    v_missing text;
BEGIN
    SELECT string_agg(c, ', ' ORDER BY c) INTO v_missing
    FROM (SELECT c FROM unnest(ARRAY['BEV', 'BAKE', 'DAIRY', 'SNACK', 'HOME', 'FRESH']) c
          EXCEPT SELECT code FROM core.category) m;
    IF v_missing IS NOT NULL OR (SELECT count(*) FROM core.category) IS DISTINCT FROM 6::bigint THEN
        RAISE EXCEPTION 'TEST FAILED: want exactly the six seeded categories, missing: %, count: %',
            v_missing, (SELECT count(*) FROM core.category);
    END IF;

    SELECT string_agg(p, ', ' ORDER BY p) INTO v_missing
    FROM (SELECT p FROM unnest(ARRAY[
              'P-1001', 'P-1002', 'P-1003', 'P-1004', 'P-2001', 'P-2002', 'P-2003', 'P-2004',
              'P-3001', 'P-3002', 'P-3003', 'P-3004', 'P-4001', 'P-4002', 'P-4003', 'P-4004',
              'P-5001', 'P-5002', 'P-5003', 'P-5004', 'P-6001', 'P-6002',
              'P-4005', 'P-3005', 'P-5005']) p
          EXCEPT SELECT product_code FROM core.vw_product) m;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: seeded products missing from core.vw_product: %', v_missing;
    END IF;
    RAISE NOTICE '  + catalogue seeded: 6 categories, the 25 demo products';
END $$;

-- The table refuses a price that is not a positive, finite number.
DO $$
DECLARE
    v_case       record;
    v_constraint text;
BEGIN
    FOR v_case IN SELECT * FROM (VALUES
        ('X-ZERO', 0::numeric, 'product_unit_price_check'),
        ('X-NEG', -1::numeric, 'product_unit_price_check'),
        ('X-NAN', 'NaN'::numeric, 'product_unit_price_finite_check')) AS t(code, price, want)
    LOOP
        v_constraint := NULL;
        BEGIN
            PERFORM core.fn_add_product(v_case.code, 'Probe', 'BEV', v_case.price);
        EXCEPTION WHEN check_violation THEN
            GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        END;
        IF v_constraint IS DISTINCT FROM v_case.want THEN
            RAISE EXCEPTION 'TEST FAILED: price % must be refused by %, got %', v_case.price, v_case.want, v_constraint;
        END IF;
    END LOOP;

    IF (core.fn_add_product('P-1001', 'Another name', 'BEV', 9.99)).product_code IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: core.fn_add_product must leave an existing product alone';
    END IF;
END $$;

-- An approved fix survives the seed running again, as it does on the next deploy.
DO $$
DECLARE
    v_acme  uuid := current_setting('test.patch_acme')::uuid;
    v_price numeric;
    v_new   numeric;
    v_patch core.patch;
    v_seed  text;
BEGIN
    SELECT unit_price INTO STRICT v_price FROM core.product WHERE product_code = 'P-1001';
    v_new := v_price + 1;

    PERFORM pg_temp.patch_act_as('uma', v_acme);
    v_patch := core.fn_submit_patch('fix.xlsx', jsonb_build_array(jsonb_build_object(
        'line_no', 2, 'product_code', 'P-1001', 'field', 'unit_price', 'new_value', v_new::text, 'reason', 'new list price')));
    PERFORM pg_temp.patch_act_as('ann', v_acme);
    IF (core.fn_approve_patch(v_patch.object_id)).state IS DISTINCT FROM 'approved' THEN
        RAISE EXCEPTION 'TEST FAILED: the approver must approve the fix, problem: %',
            core.fn_patch_problem(v_patch.object_id, 'approve');
    END IF;
    PERFORM pg_temp.test_act_as(NULL);

    SELECT s.content INTO STRICT v_seed FROM pg_temp.pgmi_source_view s WHERE s.path = './core/catalogue-seed.sql';
    EXECUTE v_seed;

    IF (SELECT unit_price FROM core.product WHERE product_code = 'P-1001') IS DISTINCT FROM v_new THEN
        RAISE EXCEPTION 'TEST FAILED: the seed reset an approved price: want %, got %',
            v_new, (SELECT unit_price FROM core.product WHERE product_code = 'P-1001');
    END IF;
END $$;
