"""Plain messages for the problem codes the database returns.

Line problems come from core.fn_patch_line_problems, patch refusals from
core.fn_patch_problem (db/core/patch.sql), as the REST routes answer them
(db/README.md). A test fails when the SQL gains a code that has no message
here.
"""

PROBLEMS: dict[str, str] = {
    "core.patch_line.product_not_found": "No product has this code.",
    "core.patch_line.field_unknown": "The field must be name, category, unit_price or active.",
    "core.patch_line.duplicate": "An earlier line already changes this field of this product.",
    "core.patch_line.reason_required": "Give a reason for the change.",
    "core.patch_line.value_invalid": "This value is not allowed for the field.",
    "core.patch_line.value_unchanged": "The product already has this value.",
    "core.patch.not_found": "This change request does not exist, or you may not see it.",
    "core.patch.not_approver": "Only approvers may decide on a change request.",
    "core.patch.own_patch": "Someone else must decide on your own change request.",
    "core.patch.not_pending": "This change request is no longer waiting for a decision.",
    "core.patch.stale": "A product changed after the upload. Upload the file again.",
}


def problem_message(code: str | None) -> str:
    """The message for a code; an unknown code is shown as it is."""
    if code is None:
        return ""
    return PROBLEMS.get(code, code)
