import pytest
from patch_desk_job import (
    LoginAccess,
    Member,
    apply_login_access,
    create_login_roles,
    demo_owner,
    plan_login_access,
    plan_members,
    template_roles,
)

UMA, ANN, BOB = "uma@example.com", "ann@example.com", "bob@example.com"
FULL = LoginAccess(exists=True, connect=True, caller=True)


def mapped_member(role: str, *extra: str) -> Member:
    return Member(principal="p", membership="m", roles=frozenset({role, *extra}), mapped=True)


def test_approvers_win_and_each_person_gets_one_patch_desk_role():
    want = template_roles({UMA, BOB}, {BOB, ANN})
    assert want == {UMA: "patch.uploader", BOB: "patch.approver", ANN: "patch.approver"}


def test_the_owner_is_the_first_approver_by_user_name_and_nobody_without_approvers():
    assert demo_owner({BOB, ANN}) == ANN
    assert demo_owner(set()) is None


def test_a_new_person_gets_a_role_connect_the_caller_role_and_a_mapped_membership():
    assert plan_login_access({UMA}, {}) == [
        ("create_role", UMA), ("grant_connect", UMA), ("grant_caller", UMA)]
    assert plan_members({UMA: "patch.uploader"}, {}) == [
        ("create_principal", UMA, ""), ("add_member", UMA, "patch.uploader"), ("map", UMA, "")]


def test_an_existing_login_role_is_not_created_again():
    steps = plan_login_access({UMA}, {UMA: LoginAccess(exists=True)})
    assert ("create_role", UMA) not in steps
    assert steps == [("grant_connect", UMA), ("grant_caller", UMA)]


def test_an_existing_principal_from_another_sign_in_is_reused():
    steps = plan_members({UMA: "patch.uploader"}, {UMA: Member(principal="p")})
    assert steps == [("add_member", UMA, "patch.uploader"), ("map", UMA, "")]


def test_a_second_run_changes_nothing():
    want = template_roles({UMA}, {ANN})
    assert plan_login_access(set(want), {UMA: FULL, ANN: FULL}) == []
    assert plan_members(want, {UMA: mapped_member("patch.uploader"),
                               ANN: mapped_member("patch.approver", "org.owner")}) == []


def test_a_person_who_left_both_groups_loses_connect_the_caller_role_and_the_membership():
    assert plan_login_access(set(), {UMA: FULL}) == [("revoke_connect", UMA), ("revoke_caller", UMA)]
    assert plan_members({}, {UMA: mapped_member("patch.uploader")}) == [("end_membership", UMA, "")]


def test_a_person_who_left_is_left_alone_on_the_next_run():
    assert plan_login_access(set(), {UMA: LoginAccess(exists=True)}) == []
    assert plan_members({}, {UMA: Member(principal="p", mapped=True)}) == []


def test_the_owner_who_left_loses_access_but_keeps_the_membership():
    assert plan_login_access(set(), {ANN: FULL}) == [("revoke_connect", ANN), ("revoke_caller", ANN)]
    assert plan_members({}, {ANN: mapped_member("patch.approver", "org.owner")}) == []


def test_an_approver_moved_to_uploader_loses_patch_approver():
    steps = plan_members({BOB: "patch.uploader"}, {BOB: mapped_member("patch.approver")})
    assert steps == [("grant_role", BOB, "patch.uploader"), ("revoke_role", BOB, "patch.approver")]


def test_the_owner_gets_patch_approver_next_to_org_owner():
    steps = plan_members({ANN: "patch.approver"},
                         {ANN: Member(principal="p", membership="m", roles=frozenset({"org.owner"}))})
    assert steps == [("grant_role", ANN, "patch.approver"), ("map", ANN, "")]


def test_other_template_roles_are_left_alone():
    assert plan_members({UMA: "patch.uploader"}, {UMA: mapped_member("patch.uploader", "org.viewer")}) == []


def test_empty_groups_plan_nothing_for_nobody():
    assert template_roles(set(), set()) == {}
    assert plan_login_access(set(), {}) == []
    assert plan_members({}, {}) == []


class RecordingConnection:
    """Records each statement; answers the missing-roles query with `missing`."""

    def __init__(self, missing: list[str] | None = None) -> None:
        self.missing = missing or []
        self.statements: list[str] = []

    def run(self, sql: str, **params) -> list:
        self.statements.append(" ".join(sql.split()))
        if "FROM unnest" in sql:
            return [[name] for name in self.missing]
        return []


def test_missing_login_roles_are_made_with_the_extension_first():
    conn = RecordingConnection(missing=[ANN, UMA])
    assert create_login_roles(conn, [ANN, BOB, UMA]) == 2
    assert conn.statements[1:] == [
        "CREATE EXTENSION IF NOT EXISTS databricks_auth",
        "SELECT databricks_create_role(:name, 'USER')",
        "SELECT databricks_create_role(:name, 'USER')"]


def test_no_missing_login_role_means_no_extension():
    conn = RecordingConnection()
    assert create_login_roles(conn, [UMA]) == 0
    assert not any("EXTENSION" in s or "databricks_create_role" in s for s in conn.statements)


def test_the_template_database_never_gets_a_role_or_the_extension():
    conn = RecordingConnection()
    with pytest.raises(RuntimeError):
        apply_login_access(conn, [("create_role", UMA), ("grant_connect", UMA)], "lakebase_apps_caller")
    assert conn.statements == []
