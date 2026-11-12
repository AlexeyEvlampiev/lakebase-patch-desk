/*
<pgmi-meta id="d72a160f-4234-4e5a-9b10-3f9525942da4" idempotent="false">
  <description>Patches, their lines and their audit trail: one organization's rows, with forced row-level security.</description>
  <sortKeys><key>005/100/patch/1</key></sortKeys>
</pgmi-meta>
*/

-- One uploaded file of fixes. created_by_user_id is the submitting principal
-- (a person, or a service such as an agent: membership.principal.kind);
-- decided_by_user_id the principal who approved or rejected it.
CREATE TABLE core.patch (
    object_id          core.entity_id PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
    organization_id    uuid NOT NULL,
    created_by_user_id uuid NOT NULL,
    file_name          text NOT NULL CONSTRAINT patch_file_name_check CHECK (btrim(file_name) <> ''),
    state              text NOT NULL
                       CONSTRAINT patch_state_check CHECK (state IN ('invalid', 'pending', 'approved', 'rejected')),
    decided_by_user_id uuid,
    decided_at         timestamptz,
    decision_note      text,
    exported_at        timestamptz,
    CONSTRAINT patch_organization_object_key UNIQUE (organization_id, object_id),
    -- Four eyes: nobody decides their own patch.
    CONSTRAINT patch_four_eyes_check CHECK (decided_by_user_id IS DISTINCT FROM created_by_user_id),
    -- A decided patch says who decided and when; an open one says neither.
    CONSTRAINT patch_decision_check CHECK (
        (state IN ('approved', 'rejected')) = (decided_by_user_id IS NOT NULL AND decided_at IS NOT NULL)
        AND (decided_by_user_id IS NULL) = (decided_at IS NULL)),
    -- Only an approved patch reaches the lakehouse.
    CONSTRAINT patch_exported_check CHECK (exported_at IS NULL OR state = 'approved')
);
CREATE INDEX ix_patch_organization_state ON core.patch (organization_id, state);
CREATE INDEX ix_patch_organization_submitter ON core.patch (organization_id, created_by_user_id);

-- One row of the uploaded file, as typed. A line may name a product or field
-- that does not exist: that is a problem to show, not a row to refuse. Only
-- lines without a problem must be unique per product and field: those are
-- the ones approval applies.
CREATE TABLE core.patch_line (
    organization_id uuid NOT NULL,
    patch_id        uuid NOT NULL,
    line_no         integer NOT NULL CONSTRAINT patch_line_line_no_check CHECK (line_no > 0),
    product_code    text,
    field           text,
    new_value       text,
    reason          text,
    old_value       text,
    problem         text,
    CONSTRAINT patch_line_pkey PRIMARY KEY (organization_id, patch_id, line_no),
    CONSTRAINT patch_line_patch_fkey FOREIGN KEY (organization_id, patch_id)
        REFERENCES core.patch (organization_id, object_id)
);
CREATE UNIQUE INDEX patch_line_product_field_key
    ON core.patch_line (organization_id, patch_id, product_code, field)
    WHERE problem IS NULL;

-- The audit trail: append-only, one row per step. created_by_user_id is the
-- principal who took the step.
CREATE TABLE core.patch_event (
    event_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organization_id    uuid NOT NULL,
    patch_id           uuid NOT NULL,
    created_by_user_id uuid NOT NULL,
    event              text NOT NULL
                       CONSTRAINT patch_event_event_check CHECK (event IN ('submitted', 'approved', 'rejected', 'exported')),
    at                 timestamptz NOT NULL DEFAULT now(),
    note               text,
    CONSTRAINT patch_event_patch_fkey FOREIGN KEY (organization_id, patch_id)
        REFERENCES core.patch (organization_id, object_id)
);
CREATE INDEX ix_patch_event_patch ON core.patch_event (organization_id, patch_id);

COMMENT ON TABLE core.patch IS 'One uploaded file of fixes, in one organization.';
COMMENT ON TABLE core.patch_line IS 'One row of an uploaded file, with the value seen at upload and its problem, if any.';
COMMENT ON TABLE core.patch_event IS 'Append-only audit trail of every patch step.';

SELECT pg_temp.apply_entity_table_standards('core.patch');

-- The organization: every row belongs to the request's organization, and a
-- new patch or event names the request's principal (core.apply_org_rls).
SELECT core.apply_org_rls('core.patch');
SELECT core.apply_org_rls('core.patch_line', p_has_created_by => false);
SELECT core.apply_org_rls('core.patch_event');

-- Within the organization (restrictive policies, so they narrow the ones
-- above): a submitter sees their own patches, a holder of patch.decide sees
-- every patch; only a holder of patch.submit creates one and only a holder of
-- patch.decide changes one. Lines and events are visible exactly when their
-- patch is; they are never changed or removed.
CREATE POLICY patch_own_or_decider ON core.patch AS RESTRICTIVE FOR SELECT
    USING (created_by_user_id = (SELECT api.current_principal_id())
           OR (SELECT api.has_permission('patch.decide')));
CREATE POLICY patch_submitter_inserts ON core.patch AS RESTRICTIVE FOR INSERT
    WITH CHECK ((SELECT api.has_permission('patch.submit')));
CREATE POLICY patch_decider_updates ON core.patch AS RESTRICTIVE FOR UPDATE
    USING ((SELECT api.has_permission('patch.decide')))
    WITH CHECK ((SELECT api.has_permission('patch.decide')));
CREATE POLICY patch_never_deleted ON core.patch AS RESTRICTIVE FOR DELETE
    USING (false);

CREATE POLICY patch_line_with_patch ON core.patch_line AS RESTRICTIVE FOR SELECT
    USING (EXISTS (SELECT FROM core.patch p
                   WHERE p.organization_id = patch_line.organization_id AND p.object_id = patch_line.patch_id));
CREATE POLICY patch_line_insert_with_patch ON core.patch_line AS RESTRICTIVE FOR INSERT
    WITH CHECK (EXISTS (SELECT FROM core.patch p
                        WHERE p.organization_id = patch_line.organization_id AND p.object_id = patch_line.patch_id));
CREATE POLICY patch_line_never_updated ON core.patch_line AS RESTRICTIVE FOR UPDATE
    USING (false);
CREATE POLICY patch_line_never_deleted ON core.patch_line AS RESTRICTIVE FOR DELETE
    USING (false);

CREATE POLICY patch_event_with_patch ON core.patch_event AS RESTRICTIVE FOR SELECT
    USING (EXISTS (SELECT FROM core.patch p
                   WHERE p.organization_id = patch_event.organization_id AND p.object_id = patch_event.patch_id));
CREATE POLICY patch_event_insert_with_patch ON core.patch_event AS RESTRICTIVE FOR INSERT
    WITH CHECK (EXISTS (SELECT FROM core.patch p
                        WHERE p.organization_id = patch_event.organization_id AND p.object_id = patch_event.patch_id));
CREATE POLICY patch_event_never_updated ON core.patch_event AS RESTRICTIVE FOR UPDATE
    USING (false);
CREATE POLICY patch_event_never_deleted ON core.patch_event AS RESTRICTIVE FOR DELETE
    USING (false);
