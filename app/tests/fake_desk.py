"""A stand-in for db.Desk, seeded into st.session_state by AppTest. It answers
what db.Desk returns from the REST routes: datetimes, uuids as text, the
refusal codes of db/core/patch.sql."""

import datetime

WHEN = datetime.datetime(2026, 11, 9, 12, 0, tzinfo=datetime.UTC)


class FakeDesk:
    user = "approver@example.com"

    def __init__(self, approver=True, refusal=None):
        self.approver = approver
        self.refusal = refusal
        self.calls = []
        self.pending = [
            {
                "patch_id": "p-own",
                "file_name": "mine.xlsx",
                "submitted_by": self.user,
                "submitted_at": WHEN,
                "line_count": 1,
                "approve_problem": "core.patch.own_patch",
                "own": True,
                "by_agent": False,
            },
            {
                "patch_id": "p-other",
                "file_name": "theirs.xlsx",
                "submitted_by": "uploader@example.com",
                "submitted_at": WHEN,
                "line_count": 1,
                "approve_problem": None,
                "own": False,
                "by_agent": False,
            },
        ]

    def is_approver(self):
        return self.approver

    def has_access(self):
        return True

    def patch_lines(self, patch_id):
        return [
            {
                "line_no": 2,
                "product_code": "P-1",
                "field": "unit_price",
                "new_value": "2",
                "reason": "r",
                "old_value": None,
                "problem": None,
            }
        ]

    def my_patches(self):
        return [
            {
                "patch_id": "p-own",
                "file_name": "mine.xlsx",
                "state": "pending",
                "submitted_at": WHEN,
                "line_count": 1,
                "problem_count": 0,
                "decided_by": None,
                "decided_at": None,
                "decision_note": None,
                "exported_at": None,
            },
            {
                "patch_id": "p-sent",
                "file_name": "prices.xlsx",
                "state": "approved",
                "submitted_at": WHEN,
                "line_count": 2,
                "problem_count": 0,
                "decided_by": "uploader@example.com",
                "decided_at": WHEN,
                "decision_note": None,
                "exported_at": WHEN,
            },
        ]

    def pending_patches(self):
        return [p for p in self.pending if p["patch_id"] not in {c[1] for c in self.calls}]

    def history(self):
        return [
            {
                "at": WHEN,
                "file_name": "mine.xlsx",
                "event": "submitted",
                "actor": self.user,
                "note": None,
                "actor_is_agent": False,
            },
            {
                "at": WHEN,
                "file_name": "prices.xlsx",
                "event": "exported",
                "actor": "00000000-0000-0000-0000-0000000e4907",
                "note": None,
                "actor_is_agent": False,
            },
        ]

    def approve(self, patch_id, note):
        self.calls.append(("approve", patch_id, note))
        return self.refusal

    def reject(self, patch_id, note):
        self.calls.append(("reject", patch_id, note))
        return self.refusal
