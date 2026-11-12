import pytest
from patch_desk_job import (
    ADMIN_PASSWORD_ENV,
    pgmi_command,
    pgmi_environment,
    workspace_oidc_issuer_param,
)

CONN = "postgresql://sp:token@host:5432/databricks_postgres?sslmode=require"


def test_the_command_passes_env_and_every_param_in_order():
    cmd = pgmi_command("pgmi", "/w/db", "lakebase_apps", "test",
                       [r"provider_role_pattern=databricks\_%", 'oidc_issuers=["https://h/oidc"]'])
    assert cmd == ["pgmi", "deploy", "/w/db", "-d", "lakebase_apps", "--param", "env=test",
                   "--param", r"provider_role_pattern=databricks\_%",
                   "--param", 'oidc_issuers=["https://h/oidc"]', "--force"]


def test_the_command_without_params_passes_only_env():
    assert pgmi_command("pgmi", "/w/db", "lakebase_apps", "test", []) == [
        "pgmi", "deploy", "/w/db", "-d", "lakebase_apps", "--param", "env=test", "--force"]


@pytest.mark.parametrize("param", ["no-equals-sign", "=value", "env=prod", "Database_Admin_Password=x"])
def test_a_malformed_or_reserved_param_is_refused(param):
    with pytest.raises(RuntimeError):
        pgmi_command("pgmi", "/w/db", "lakebase_apps", "test", [param])


def test_the_admin_password_is_fresh_and_only_in_the_environment():
    first = pgmi_environment({"PATH": "/bin"}, CONN, admin_password=True)
    second = pgmi_environment({"PATH": "/bin"}, CONN, admin_password=True)
    assert first["PGMI_CONNECTION_STRING"] == CONN
    assert first["PATH"] == "/bin"
    assert len(first[ADMIN_PASSWORD_ENV]) >= 32
    assert first[ADMIN_PASSWORD_ENV] != second[ADMIN_PASSWORD_ENV]
    cmd = pgmi_command("pgmi", "/w/db", "lakebase_apps", "test", [])
    assert not any(first[ADMIN_PASSWORD_ENV] in part for part in cmd)


def test_without_the_flag_no_admin_password_reaches_pgmi():
    env = pgmi_environment({ADMIN_PASSWORD_ENV: "inherited"}, CONN, admin_password=False)
    assert ADMIN_PASSWORD_ENV not in env


def test_the_workspace_issuer_is_the_host_with_oidc():
    assert workspace_oidc_issuer_param("https://workspace.example.com/") == \
        'oidc_issuers=["https://workspace.example.com/oidc"]'
    with pytest.raises(RuntimeError):
        workspace_oidc_issuer_param("")
