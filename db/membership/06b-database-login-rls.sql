/*
<pgmi-meta
    id="3f6c2a10-7b1e-4c55-9d0e-5a1b2c3d4e02"
    idempotent="false">
  <description>
    Row-level security on membership.database_login: a principal reads its
    own mapping, a platform operator reads all; only the kernel writes.
  </description>
  <sortKeys>
    <key>005/000/006/002</key>
  </sortKeys>
</pgmi-meta>
*/

ALTER TABLE membership.database_login ENABLE ROW LEVEL SECURITY;
ALTER TABLE membership.database_login FORCE ROW LEVEL SECURITY;

CREATE POLICY database_login_visible ON membership.database_login FOR SELECT
    USING (principal_object_id = (SELECT api.current_principal_id()) OR (SELECT api.is_platform_operator()));

SELECT pg_temp.kernel_passes('membership.database_login'::regclass, '{select,insert}');
