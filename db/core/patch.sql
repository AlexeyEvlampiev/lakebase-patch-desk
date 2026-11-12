/*
<pgmi-meta id="18df4d4c-2fa4-4909-87dc-6967fdbb4b64" idempotent="true">
  <description>Patch kernels and views: line checks, submit, approve, reject, and the read views.</description>
  <sortKeys><key>005/100/patch/2</key></sortKeys>
</pgmi-meta>
*/
-- Kernels run with the caller's rights: as the owner, which runs every
-- handler, held by the forced row-level security of core/patch-structure.sql
-- to the request's organization and principal. Each returns the affected
-- patch, or a row of NULLs when its rule refuses; the problem functions say
-- why.
--
-- Line shape. A caller sends a JSON array of objects
--   {"line_no": <row number in the file>, "product_code": text, "field": text,
--    "new_value": text, "reason": text}
-- with every value as typed in the file; a missing key is NULL.

-- The lines of a file, normalized: product code and field trimmed, field in
-- lower case. new_value and reason stay as typed. A line_no that is not an
-- integer reads as NULL (core.fn_patch_problems refuses the file).
CREATE OR REPLACE FUNCTION core.fn_patch_lines(p_lines jsonb)
RETURNS TABLE (line_no integer, product_code text, field text, new_value text, reason text)
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN pg_input_is_valid(e ->> 'line_no', 'integer') THEN (e ->> 'line_no')::integer END,
           NULLIF(btrim(e ->> 'product_code'), ''),
           NULLIF(lower(btrim(e ->> 'field')), ''),
           e ->> 'new_value',
           e ->> 'reason'
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_lines) = 'array' THEN p_lines ELSE '[]' END) AS e
    WHERE jsonb_typeof(e) = 'object';
$$;

-- What keeps a file from being stored at all, as (field, reason):
--   file_name required   blank or missing
--   lines     required   not an array, or no lines
--   lines     invalid    a line that is not an object, or whose line_no is
--                        missing, not a positive integer, or repeated
CREATE OR REPLACE FUNCTION core.fn_patch_problems(p_file_name text, p_lines jsonb)
RETURNS TABLE (field text, reason text)
LANGUAGE sql STABLE AS $$
    SELECT field, reason FROM (VALUES
        ('file_name', CASE WHEN p_file_name IS NULL OR btrim(p_file_name) = '' THEN 'required' END),
        ('lines', CASE
            WHEN jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) = 0 THEN 'required'
            WHEN EXISTS (SELECT FROM jsonb_array_elements(p_lines) e WHERE jsonb_typeof(e) <> 'object')
              OR EXISTS (SELECT FROM core.fn_patch_lines(p_lines) l WHERE l.line_no IS NULL OR l.line_no < 1)
              OR (SELECT count(DISTINCT l.line_no) <> count(*) FROM core.fn_patch_lines(p_lines) l) THEN 'invalid'
        END)
    ) AS p(field, reason)
    WHERE reason IS NOT NULL;
$$;

-- One problem per line, or NULL when the line is fine. One statement over the
-- whole file. Precedence, first match wins:
--   core.patch_line.product_not_found  the product code is not in the catalogue
--   core.patch_line.field_unknown      the field is not name, category, unit_price or active
--   core.patch_line.duplicate          an earlier line (lower line_no) has the same product and field
--   core.patch_line.reason_required    the reason is blank
--   core.patch_line.value_invalid      the value does not cast, or would break a table rule
--                                      (blank name, unknown category, price not > 0, NaN)
--   core.patch_line.value_unchanged    the value equals the product's current value
CREATE OR REPLACE FUNCTION core.fn_patch_line_problems(p_lines jsonb)
RETURNS TABLE (line_no integer, problem text)
LANGUAGE sql STABLE AS $$
    WITH line AS (
        SELECT l.*,
               row_number() OVER (PARTITION BY l.product_code, l.field ORDER BY l.line_no) AS nth,
               btrim(l.new_value) AS v
        FROM core.fn_patch_lines(p_lines) l
    ),
    checked AS (
        SELECT l.line_no,
               l.field,
               l.v,
               l.nth,
               l.reason,
               p AS product,
               -- Typed checks; each cast runs only after its validity test.
               CASE l.field
                   WHEN 'name'       THEN COALESCE(l.v, '') <> ''
                   WHEN 'category'   THEN EXISTS (SELECT FROM core.category c WHERE c.code = l.v)
                   WHEN 'unit_price' THEN CASE WHEN COALESCE(pg_input_is_valid(l.v, 'numeric(12,2)'), false)
                                               THEN l.v::numeric(12,2) > 0 AND l.v::numeric(12,2) <> 'NaN'
                                               ELSE false END
                   WHEN 'active'     THEN COALESCE(pg_input_is_valid(l.v, 'boolean'), false)
               END AS value_ok
        FROM line l
        LEFT JOIN core.product p ON p.product_code = l.product_code
    )
    SELECT c.line_no,
           CASE
               WHEN (c.product).product_code IS NULL                          THEN 'core.patch_line.product_not_found'
               WHEN c.field IS NULL
                 OR c.field NOT IN ('name', 'category', 'unit_price', 'active') THEN 'core.patch_line.field_unknown'
               WHEN c.nth > 1                                                 THEN 'core.patch_line.duplicate'
               WHEN COALESCE(btrim(c.reason), '') = ''                        THEN 'core.patch_line.reason_required'
               WHEN NOT c.value_ok                                            THEN 'core.patch_line.value_invalid'
               WHEN CASE c.field
                        WHEN 'name'       THEN c.v = (c.product).name
                        WHEN 'category'   THEN c.v = (c.product).category
                        WHEN 'unit_price' THEN c.v::numeric(12,2) = (c.product).unit_price
                        WHEN 'active'     THEN c.v::boolean = (c.product).active
                    END                                                       THEN 'core.patch_line.value_unchanged'
           END
    FROM checked c
    ORDER BY c.line_no;
$$;

-- Why an operation on a patch is refused, or NULL when it may go ahead.
-- p_operation is 'approve' or 'reject'. Reads through row-level security, so
-- a patch the caller may not see is core.patch.not_found.
CREATE OR REPLACE FUNCTION core.fn_patch_problem(p_patch_id uuid, p_operation text)
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN p.object_id IS NULL                                    THEN 'core.patch.not_found'
        WHEN NOT COALESCE((SELECT api.has_permission('patch.decide')), false) THEN 'core.patch.not_approver'
        WHEN p.created_by_user_id = (SELECT api.current_principal_id()) THEN 'core.patch.own_patch'
        WHEN p.state <> 'pending'                                   THEN 'core.patch.not_pending'
        WHEN p_operation = 'approve' AND EXISTS (
                 SELECT
                 FROM core.patch_line l
                 JOIN core.product pr ON pr.product_code = l.product_code
                 WHERE l.organization_id = p.organization_id
                   AND l.patch_id = p.object_id
                   AND l.problem IS NULL
                   AND core.fn_product_field_text(pr, l.field) IS DISTINCT FROM l.old_value)
                                                                    THEN 'core.patch.stale'
    END
    FROM (SELECT p_patch_id) AS k(id)
    LEFT JOIN core.patch p ON p.object_id = k.id;
$$;

-- Store an uploaded file in the request's organization: the patch, every line
-- with the value seen now and its problem, and the 'submitted' event. A file
-- with any line problem is stored as 'invalid' so the submitter sees what to
-- fix; otherwise 'pending'. Refuses a file core.fn_patch_problems names.
CREATE OR REPLACE FUNCTION core.fn_submit_patch(p_file_name text, p_lines jsonb)
RETURNS core.patch
LANGUAGE plpgsql AS $$
DECLARE
    v_patch core.patch;
BEGIN
    IF EXISTS (SELECT FROM core.fn_patch_problems(p_file_name, p_lines)) THEN
        RETURN NULL;
    END IF;

    INSERT INTO core.patch (organization_id, created_by_user_id, file_name, state)
    SELECT api.current_organization_id(), api.current_principal_id(), btrim(p_file_name),
           CASE WHEN bool_or(lp.problem IS NOT NULL) THEN 'invalid' ELSE 'pending' END
    FROM core.fn_patch_line_problems(p_lines) lp
    RETURNING * INTO STRICT v_patch;

    INSERT INTO core.patch_line
        (organization_id, patch_id, line_no, product_code, field, new_value, reason, old_value, problem)
    SELECT v_patch.organization_id, v_patch.object_id, l.line_no, l.product_code, l.field, l.new_value, l.reason,
           core.fn_product_field_text(p, l.field),
           lp.problem
    FROM core.fn_patch_lines(p_lines) l
    JOIN core.fn_patch_line_problems(p_lines) lp ON lp.line_no = l.line_no
    LEFT JOIN core.product p ON p.product_code = l.product_code;

    INSERT INTO core.patch_event (organization_id, patch_id, created_by_user_id, event)
    VALUES (v_patch.organization_id, v_patch.object_id, v_patch.created_by_user_id, 'submitted');
    RETURN v_patch;
END $$;

-- Approve a pending patch: apply every clean line to the catalogue, all or
-- none, in the caller's transaction. Locks the patch, then its products in a
-- fixed order, and refuses if a product changed since upload
-- (core.patch.stale).
CREATE OR REPLACE FUNCTION core.fn_approve_patch(p_patch_id uuid, p_note text DEFAULT NULL)
RETURNS core.patch
LANGUAGE plpgsql AS $$
DECLARE
    v_patch core.patch;
BEGIN
    PERFORM FROM core.patch WHERE object_id = p_patch_id FOR UPDATE;
    PERFORM
    FROM core.product
    WHERE product_code IN (SELECT l.product_code FROM core.patch_line l
                           WHERE l.patch_id = p_patch_id AND l.problem IS NULL)
    ORDER BY product_code
    FOR UPDATE;

    IF core.fn_patch_problem(p_patch_id, 'approve') IS NOT NULL THEN
        RETURN NULL;
    END IF;

    -- A product may have several lines (one per field); fold them into one row.
    UPDATE core.product p
    SET name       = COALESCE(c.name, p.name),
        category   = COALESCE(c.category, p.category),
        unit_price = COALESCE(c.unit_price, p.unit_price),
        active     = COALESCE(c.active, p.active),
        updated_at = now()
    FROM (
        SELECT l.product_code,
               max(CASE WHEN l.field = 'name'       THEN btrim(l.new_value) END)                AS name,
               max(CASE WHEN l.field = 'category'   THEN btrim(l.new_value) END)                AS category,
               max(CASE WHEN l.field = 'unit_price' THEN btrim(l.new_value)::numeric(12,2) END) AS unit_price,
               bool_or(CASE WHEN l.field = 'active' THEN btrim(l.new_value)::boolean END)       AS active
        FROM core.patch_line l
        WHERE l.patch_id = p_patch_id AND l.problem IS NULL
        GROUP BY l.product_code
    ) c
    WHERE p.product_code = c.product_code;

    UPDATE core.patch
    SET state = 'approved', decided_by_user_id = api.current_principal_id(), decided_at = now(), decision_note = p_note
    WHERE object_id = p_patch_id AND state = 'pending'
    RETURNING * INTO STRICT v_patch;

    INSERT INTO core.patch_event (organization_id, patch_id, created_by_user_id, event, note)
    VALUES (v_patch.organization_id, v_patch.object_id, v_patch.decided_by_user_id, 'approved', p_note);
    RETURN v_patch;
END $$;

-- Reject a pending patch. Nothing is applied.
CREATE OR REPLACE FUNCTION core.fn_reject_patch(p_patch_id uuid, p_note text DEFAULT NULL)
RETURNS core.patch
LANGUAGE plpgsql AS $$
DECLARE
    v_patch core.patch;
BEGIN
    PERFORM FROM core.patch WHERE object_id = p_patch_id FOR UPDATE;
    IF core.fn_patch_problem(p_patch_id, 'reject') IS NOT NULL THEN
        RETURN NULL;
    END IF;

    UPDATE core.patch
    SET state = 'rejected', decided_by_user_id = api.current_principal_id(), decided_at = now(), decision_note = p_note
    WHERE object_id = p_patch_id AND state = 'pending'
    RETURNING * INTO STRICT v_patch;

    INSERT INTO core.patch_event (organization_id, patch_id, created_by_user_id, event, note)
    VALUES (v_patch.organization_id, v_patch.object_id, v_patch.decided_by_user_id, 'rejected', p_note);
    RETURN v_patch;
END $$;

-- Read views. security_invoker: the reader's row-level security applies, so
-- a submitter sees only their own patches here too.
SELECT core.ensure_view('core.vw_patch', $view$
    CREATE OR REPLACE VIEW core.vw_patch WITH (security_invoker = true) AS
    SELECT p.object_id,
           p.file_name,
           p.created_by_user_id,
           p.created_at,
           p.state,
           p.decided_by_user_id,
           p.decided_at,
           p.decision_note,
           p.exported_at,
           (SELECT count(*) FROM core.patch_line l
            WHERE l.organization_id = p.organization_id AND l.patch_id = p.object_id) AS line_count,
           (SELECT count(*) FROM core.patch_line l
            WHERE l.organization_id = p.organization_id AND l.patch_id = p.object_id
              AND l.problem IS NOT NULL) AS problem_count,
           core.fn_patch_problem(p.object_id, 'approve') AS approve_problem
    FROM core.patch p
    WHERE p.deleted_at IS NULL
$view$);
COMMENT ON VIEW core.vw_patch IS 'The patches the reader may see in the request''s organization: their own, or all with patch.decide.';
COMMENT ON COLUMN core.vw_patch.object_id IS 'The patch''s id.';
COMMENT ON COLUMN core.vw_patch.file_name IS 'The name of the uploaded file.';
COMMENT ON COLUMN core.vw_patch.created_by_user_id IS 'The principal who submitted the patch.';
COMMENT ON COLUMN core.vw_patch.created_at IS 'When the patch was submitted; patches are listed by it.';
COMMENT ON COLUMN core.vw_patch.state IS 'invalid, pending, approved or rejected.';
COMMENT ON COLUMN core.vw_patch.decided_by_user_id IS 'The principal who approved or rejected the patch.';
COMMENT ON COLUMN core.vw_patch.decided_at IS 'When the patch was approved or rejected.';
COMMENT ON COLUMN core.vw_patch.decision_note IS 'The note given with the decision.';
COMMENT ON COLUMN core.vw_patch.exported_at IS 'When the approved patch reached the lakehouse.';
COMMENT ON COLUMN core.vw_patch.line_count IS 'How many lines the file had.';
COMMENT ON COLUMN core.vw_patch.problem_count IS 'How many lines have a problem.';
COMMENT ON COLUMN core.vw_patch.approve_problem IS 'Why the reader may not approve the patch now, or NULL (core.fn_patch_problem).';

SELECT core.ensure_view('core.vw_patch_line', $view$
    CREATE OR REPLACE VIEW core.vw_patch_line WITH (security_invoker = true) AS
    SELECT l.patch_id,
           l.line_no,
           l.product_code,
           l.field,
           l.new_value,
           l.reason,
           l.old_value,
           core.fn_product_field_text(pr, l.field) AS current_value,
           l.problem
    FROM core.patch_line l
    LEFT JOIN core.product pr ON pr.product_code = l.product_code
$view$);
COMMENT ON VIEW core.vw_patch_line IS 'The lines of the patches the reader may see, with each product''s current value.';
COMMENT ON COLUMN core.vw_patch_line.patch_id IS 'The patch the line belongs to.';
COMMENT ON COLUMN core.vw_patch_line.line_no IS 'The line''s row number in the file.';
COMMENT ON COLUMN core.vw_patch_line.product_code IS 'The product code, as typed and trimmed.';
COMMENT ON COLUMN core.vw_patch_line.field IS 'The field to change, trimmed and in lower case.';
COMMENT ON COLUMN core.vw_patch_line.new_value IS 'The new value, as typed.';
COMMENT ON COLUMN core.vw_patch_line.reason IS 'Why the value changes, as typed.';
COMMENT ON COLUMN core.vw_patch_line.old_value IS 'The value at upload.';
COMMENT ON COLUMN core.vw_patch_line.current_value IS 'The value now.';
COMMENT ON COLUMN core.vw_patch_line.problem IS 'The line''s problem code, or NULL (core.fn_patch_line_problems).';

SELECT core.ensure_view('core.vw_patch_event', $view$
    CREATE OR REPLACE VIEW core.vw_patch_event WITH (security_invoker = true) AS
    SELECT e.event_id, e.patch_id, e.event, e.created_by_user_id, e.at, e.note
    FROM core.patch_event e
$view$);
COMMENT ON VIEW core.vw_patch_event IS 'The audit trail of the patches the reader may see.';
COMMENT ON COLUMN core.vw_patch_event.event_id IS 'The event''s id, in the order events were written.';
COMMENT ON COLUMN core.vw_patch_event.patch_id IS 'The patch the event belongs to.';
COMMENT ON COLUMN core.vw_patch_event.event IS 'submitted, approved, rejected or exported.';
COMMENT ON COLUMN core.vw_patch_event.created_by_user_id IS 'The principal who took the step.';
COMMENT ON COLUMN core.vw_patch_event.at IS 'When the step was taken.';
COMMENT ON COLUMN core.vw_patch_event.note IS 'The note given with the step.';
