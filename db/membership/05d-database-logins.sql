/*
<pgmi-meta
    id="3f6c2a10-7b1e-4c55-9d0e-5a1b2c3d4e03"
    idempotent="true">
  <description>
    Kernels for database logins: map a login role to a principal (outside a
    request, as the deploy or the provisioning job does, or by a platform
    operator), and look up the principal session_user is.
  </description>
  <sortKeys>
    <key>005/000/005/004</key>
  </sortKeys>
</pgmi-meta>
*/

-- Maps a login role to an enabled user or service principal that is a
-- current member of the organization. Mapping the same pair again returns the
-- existing row; a role or a principal mapped to something else gives NULL.
CREATE OR REPLACE FUNCTION membership.fn_map_database_login(
    p_database_role          name,
    p_principal_object_id    uuid,
    p_organization_object_id uuid)
RETURNS membership.database_login
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = membership, common, pg_temp
AS $$
DECLARE
    v_login membership.database_login;
BEGIN
    IF (api.current_principal_id() IS NOT NULL AND NOT api.is_platform_operator())
       OR to_regrole(quote_ident(p_database_role)) IS NULL
       OR NOT EXISTS (SELECT FROM membership.principal p
                      WHERE p.object_id = p_principal_object_id AND p.kind IN ('user', 'service') AND p.disabled_at IS NULL)
       OR NOT EXISTS (SELECT FROM membership.organization_membership m
                      JOIN membership.organization o ON o.object_id = m.organization_object_id AND o.status = 'active'
                      WHERE m.principal_object_id = p_principal_object_id
                        AND m.organization_object_id = p_organization_object_id
                        AND upper_inf(m.valid_during)) THEN
        RETURN NULL;
    END IF;

    INSERT INTO membership.database_login (database_role, principal_object_id, organization_object_id)
    VALUES (p_database_role, p_principal_object_id, p_organization_object_id)
    ON CONFLICT DO NOTHING
    RETURNING * INTO v_login;
    IF v_login.database_role IS NULL THEN
        SELECT * INTO v_login FROM membership.database_login
        WHERE database_role = p_database_role AND principal_object_id = p_principal_object_id;
        RETURN v_login;
    END IF;

    PERFORM membership.fn_record_audit_event('membership.database_login.mapped', p_organization_object_id,
        p_principal_object_id, jsonb_build_object('databaseRole', p_database_role));
    RETURN v_login;
END $$;

COMMENT ON FUNCTION membership.fn_map_database_login(name, uuid, uuid) IS
    'Maps a database login role to the principal it is, in its default organization. Provisioning only: owned and executed by the kernel role, outside a request.';

-- Not for handlers: provisioning calls it as the kernel role.
SELECT pg_temp.kernel_owns('membership.fn_map_database_login(name, uuid, uuid)', false);
