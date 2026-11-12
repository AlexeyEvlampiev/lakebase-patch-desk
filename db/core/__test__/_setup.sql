-- ============================================================================
-- Patch desk fixture, written through the membership kernels:
--   Acme Patch Co:  olga (test|patch-olga)  org.owner (holds every permission)
--                   uma  (test|patch-uma)   patch.uploader
--                   ann  (test|patch-ann)   patch.approver
--                   max  (test|patch-max)   org.member (no patch permission)
--   Globex Patch Co: gil (test|patch-gil)   org.owner
-- Session variables: test.patch_acme, test.patch_globex (organization ids),
-- test.patch_<name>_id (person ids).
-- pg_temp.patch_act_as(name, organization) states the request context of
-- test|patch-<name> in that organization.
-- ============================================================================

INSERT INTO membership.identity_issuer (id, kind) VALUES ('test', 'development')
ON CONFLICT (id) DO NOTHING;

DO $$
DECLARE
    v_olga   uuid := pg_temp.test_login('test', 'patch-olga', 'olga@patch.example.test', 'Olga', true);
    v_uma    uuid := pg_temp.test_login('test', 'patch-uma', 'uma@patch.example.test', 'Uma', true);
    v_ann    uuid := pg_temp.test_login('test', 'patch-ann', 'ann@patch.example.test', 'Ann', true);
    v_max    uuid := pg_temp.test_login('test', 'patch-max', 'max@patch.example.test', 'Max', true);
    v_gil    uuid := pg_temp.test_login('test', 'patch-gil', 'gil@patch.example.test', 'Gil', true);
    v_acme   uuid := (membership.fn_create_organization_with_owner('Acme Patch Co', 'acme-patch-co', v_olga)).object_id;
    v_globex uuid := (membership.fn_create_organization_with_owner('Globex Patch Co', 'globex-patch-co', v_gil)).object_id;
BEGIN
    PERFORM membership.fn_add_member(v_acme, v_uma, 'patch.uploader');
    PERFORM membership.fn_add_member(v_acme, v_ann, 'patch.approver');
    PERFORM membership.fn_add_member(v_acme, v_max, 'org.member');

    PERFORM set_config('test.patch_acme', v_acme::text, true);
    PERFORM set_config('test.patch_globex', v_globex::text, true);
    PERFORM set_config('test.patch_olga_id', v_olga::text, true);
    PERFORM set_config('test.patch_uma_id', v_uma::text, true);
    PERFORM set_config('test.patch_ann_id', v_ann::text, true);
    PERFORM set_config('test.patch_max_id', v_max::text, true);
    PERFORM set_config('test.patch_gil_id', v_gil::text, true);
END $$;

CREATE FUNCTION pg_temp.patch_act_as(p_name text, p_organization uuid DEFAULT NULL)
RETURNS void
LANGUAGE sql AS $$
    SELECT pg_temp.test_act_as('test|patch-' || p_name, p_organization);
$$;
