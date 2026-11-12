/*
<pgmi-meta id="5c0e8a31-7d42-4b6e-9f13-2a8d4c6e1b07" idempotent="true">
  <description>Patch desk reads shared by its REST routes, RPC methods and MCP tools: the JSON each one answers, built from the patch views.</description>
  <sortKeys><key>005/100/patch/3</key></sortKeys>
</pgmi-meta>
*/
-- One function per read, each LANGUAGE sql STABLE and returning jsonb, so a
-- REST route, an RPC method and an MCP tool answer the same document from one
-- snapshot. Every function reads the views of core/patch.sql (or the shared
-- catalogue), so the reader's row-level security decides what is in it.
-- Field names are the ones the app reads (snake_case).

-- How the patch desk names a principal of the request's organization: the
-- person's email, else the display name (a service has no email). NULL for a
-- principal the reader cannot see (no longer a member).
CREATE OR REPLACE FUNCTION core.fn_patch_person_name(p_principal uuid)
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT coalesce(m.email::text, m.display_name)
    FROM membership.vw_member m
    WHERE m.principal_object_id = p_principal
      AND m.organization_object_id = (SELECT api.current_organization_id());
$$;

-- Whether a principal of the request's organization is a service (such as
-- the AI agent), not a person.
CREATE OR REPLACE FUNCTION core.fn_patch_person_is_service(p_principal uuid)
RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT coalesce((SELECT m.principal_kind = 'service'
                     FROM membership.vw_member m
                     WHERE m.principal_object_id = p_principal
                       AND m.organization_object_id = (SELECT api.current_organization_id())), false);
$$;

-- One patch as every answer shows it.
CREATE OR REPLACE FUNCTION core.fn_patch_json(p core.vw_patch)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'patch_id', p.object_id,
        'file_name', p.file_name,
        'state', p.state,
        'submitted_by', core.fn_patch_person_name(p.created_by_user_id),
        'submitted_at', p.created_at,
        'line_count', p.line_count,
        'problem_count', p.problem_count,
        'decided_by', core.fn_patch_person_name(p.decided_by_user_id),
        'decided_at', p.decided_at,
        'decision_note', p.decision_note,
        'exported_at', p.exported_at,
        'approve_problem', p.approve_problem,
        'own', p.created_by_user_id = (SELECT api.current_principal_id()),
        'by_agent', core.fn_patch_person_is_service(p.created_by_user_id));
$$;

-- One patch the reader may see, as fn_patch_json; NULL when there is none.
CREATE OR REPLACE FUNCTION core.fn_patch_read(p_patch_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT core.fn_patch_json(p) FROM core.vw_patch p WHERE p.object_id = p_patch_id;
$$;

-- A page of patches. p_scope 'mine': the reader's own, newest first;
-- 'pending': every pending patch the reader may see, oldest first.
CREATE OR REPLACE FUNCTION core.fn_patch_page(p_scope text, p_limit integer, p_offset integer)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH chosen AS (
        SELECT p, row_number() OVER (
                      ORDER BY CASE WHEN p_scope = 'mine' THEN p.created_at END DESC,
                               CASE WHEN p_scope = 'mine' THEN s.seq END DESC,
                               p.created_at, s.seq) AS n
        FROM core.vw_patch p
        -- Submission order: patches submitted in one transaction share created_at.
        CROSS JOIN LATERAL (SELECT min(e.event_id) AS seq FROM core.vw_patch_event e
                            WHERE e.patch_id = p.object_id) s
        WHERE CASE p_scope
                  WHEN 'mine' THEN p.created_by_user_id = (SELECT api.current_principal_id())
                  WHEN 'pending' THEN p.state = 'pending'
              END
    ), page AS (
        SELECT c.p, c.n FROM chosen c ORDER BY c.n LIMIT p_limit OFFSET p_offset
    )
    SELECT jsonb_build_object(
        'items', coalesce((SELECT jsonb_agg(core.fn_patch_json(g.p) ORDER BY g.n) FROM page g), '[]'::jsonb),
        'total', t.total,
        'limit', p_limit,
        'offset', p_offset,
        'hasMore', p_offset + (SELECT count(*) FROM page) < t.total)
    FROM (SELECT count(*) AS total FROM chosen) t;
$$;

-- A page of the audit trail of the patches the reader may see, newest first.
CREATE OR REPLACE FUNCTION core.fn_patch_event_page(p_limit integer, p_offset integer)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH chosen AS (
        SELECT e.event_id, e.patch_id, e.event, e.created_by_user_id, e.at, e.note, p.file_name
        FROM core.vw_patch_event e
        JOIN core.vw_patch p ON p.object_id = e.patch_id
    ), page AS (
        SELECT * FROM chosen ORDER BY event_id DESC LIMIT p_limit OFFSET p_offset
    )
    SELECT jsonb_build_object(
        'items', coalesce((SELECT jsonb_agg(jsonb_build_object(
                     'patch_id', g.patch_id,
                     'at', g.at,
                     'file_name', g.file_name,
                     'event', g.event,
                     'actor', core.fn_patch_person_name(g.created_by_user_id),
                     'note', g.note,
                     'actor_is_agent', core.fn_patch_person_is_service(g.created_by_user_id))
                   ORDER BY g.event_id DESC) FROM page g), '[]'::jsonb),
        'total', t.total,
        'limit', p_limit,
        'offset', p_offset,
        'hasMore', p_offset + (SELECT count(*) FROM page) < t.total)
    FROM (SELECT count(*) AS total FROM chosen) t;
$$;

-- The lines of one patch the reader may see, in file order, as
-- {"patch": <fn_patch_json>, "lines": [...]}; NULL when the reader may not
-- see the patch (core.patch.not_found).
CREATE OR REPLACE FUNCTION core.fn_patch_line_list(p_patch_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'patch', core.fn_patch_json(p),
        'lines', coalesce((SELECT jsonb_agg(jsonb_build_object(
                     'line_no', l.line_no,
                     'product_code', l.product_code,
                     'field', l.field,
                     'new_value', l.new_value,
                     'reason', l.reason,
                     'old_value', l.old_value,
                     'current_value', l.current_value,
                     'problem', l.problem) ORDER BY l.line_no)
                   FROM core.vw_patch_line l WHERE l.patch_id = p.object_id), '[]'::jsonb))
    FROM core.vw_patch p
    WHERE p.object_id = p_patch_id;
$$;

-- The problem of each line of a draft file, before it is submitted:
-- {"lines": [{"line_no", "problem"}], "problem_count"}. The caller checks
-- the file itself first (core.fn_patch_problems, field 'lines').
CREATE OR REPLACE FUNCTION core.fn_patch_line_check(p_lines jsonb)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'lines', coalesce(jsonb_agg(jsonb_build_object('line_no', lp.line_no, 'problem', lp.problem)
                                    ORDER BY lp.line_no), '[]'::jsonb),
        'problem_count', count(*) FILTER (WHERE lp.problem IS NOT NULL))
    FROM core.fn_patch_line_problems(p_lines) lp;
$$;

-- The catalogue's categories, by name. Shared by every organization.
CREATE OR REPLACE FUNCTION core.fn_category_list()
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'name', c.name) ORDER BY c.name, c.code), '[]'::jsonb)
    FROM core.category c;
$$;

-- Who the request acts as, and what the patch desk lets them do.
CREATE OR REPLACE FUNCTION core.fn_patch_desk_caller()
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'principal_id', (SELECT api.current_principal_id()),
        'name', core.fn_patch_person_name((SELECT api.current_principal_id())),
        'actor_kind', (SELECT api.current_actor_kind()),
        'organization_id', (SELECT api.current_organization_id()),
        'can_submit', coalesce((SELECT api.has_permission('patch.submit')), false),
        'can_decide', coalesce((SELECT api.has_permission('patch.decide')), false));
$$;

-- The rule and the remedy behind a patch refusal code, for an answer an AI
-- agent reads (the app has its own messages, keyed by the code).
CREATE OR REPLACE FUNCTION core.fn_patch_refusal(p_code text)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('code', p_code) || CASE p_code
        WHEN 'core.patch.not_found' THEN jsonb_build_object(
            'rule', 'Only a patch you may see can be read or decided',
            'remedy', 'Take a patchId from list_pending_patches or list_my_patches')
        WHEN 'core.patch.not_approver' THEN jsonb_build_object(
            'rule', 'Only a holder of patch.decide approves or rejects a patch',
            'remedy', 'Ask an approver of the organization to decide')
        WHEN 'core.patch.own_patch' THEN jsonb_build_object(
            'rule', 'Nobody decides their own patch (four eyes)',
            'remedy', 'Ask another approver to decide')
        WHEN 'core.patch.not_pending' THEN jsonb_build_object(
            'rule', 'Only a pending patch can be approved or rejected',
            'remedy', 'Read its state with list_pending_patches; it was decided already, or it has line problems')
        WHEN 'core.patch.stale' THEN jsonb_build_object(
            'rule', 'A product changed after the upload, so the patch would overwrite a newer value',
            'remedy', 'Reject it and submit the file again')
        ELSE jsonb_build_object(
            'rule', 'The arguments must be well-formed',
            'remedy', 'Fix the arguments named in invalidParams and call again')
    END;
$$;
