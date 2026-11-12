/*
<pgmi-meta id="0b6f3c52-9e1a-4d7b-8c25-6a41f7d3e9b8" idempotent="false">
  <description>Lets the export kernels (core/patch-export.sql) read approved patches and mark them exported across organizations.</description>
  <sortKeys><key>005/100/patch/5</key></sortKeys>
</pgmi-meta>
*/
-- The export job runs outside any request, so the organization policies of
-- core/patch-structure.sql show it no row. Its two kernels run as the kernel
-- role, which passes by its own policies (pg_temp.kernel_passes): it reads
-- patches, their lines and the catalogue, sets exported_at and writes the
-- 'exported' event. Nothing else.
SELECT pg_temp.kernel_passes('core.patch', '{select,update}');
SELECT pg_temp.kernel_passes('core.patch_line', '{select}');
SELECT pg_temp.kernel_passes('core.patch_event', '{insert}');

DO $$
BEGIN
    -- The catalogue is shared and exempt from row-level security.
    EXECUTE format('GRANT SELECT ON core.product TO %I', pg_temp.deployment_setting('database_kernel_role'));

    -- The two restrictive policies on core.patch that hold a reader to their
    -- own patches and a writer to patch.decide are meant for requests, which
    -- run as the owner. Created without TO, they apply to every role
    -- (PUBLIC), so they would hide every patch from the kernel too. They now name the owner (and the
    -- logins that inherit it); the other patch policies stay as they are.
    EXECUTE format('ALTER POLICY patch_own_or_decider ON core.patch TO %I',
                   pg_temp.deployment_setting('database_owner_role'));
    EXECUTE format('ALTER POLICY patch_decider_updates ON core.patch TO %I',
                   pg_temp.deployment_setting('database_owner_role'));
END $$;
