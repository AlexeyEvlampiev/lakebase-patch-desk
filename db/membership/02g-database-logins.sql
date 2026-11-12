/*
<pgmi-meta
    id="3f6c2a10-7b1e-4c55-9d0e-5a1b2c3d4e01"
    idempotent="false">
  <description>
    Database logins: a database login role (Lakebase: one per person or
    service principal) mapped to the principal it is, and the organization it
    works in by default. A mapped login is attributed from session_user and
    never states its identity through auth.* settings.
  </description>
  <sortKeys>
    <key>005/000/002/007</key>
  </sortKeys>
</pgmi-meta>
*/

CREATE TABLE membership.database_login (
    database_role          name        PRIMARY KEY,
    principal_object_id    uuid        NOT NULL REFERENCES membership.principal (object_id),
    organization_object_id uuid        NOT NULL REFERENCES membership.organization (object_id),
    mapped_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT database_login_principal_key UNIQUE (principal_object_id)
);

CREATE INDEX ix_database_login_organization ON membership.database_login (organization_object_id);

COMMENT ON TABLE membership.database_login IS
    'A database login role that is a principal: the request acts for that principal whenever session_user is this role, whatever auth.* says.';
