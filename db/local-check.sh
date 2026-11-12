#!/usr/bin/env bash
# Deploy db/ into a throwaway PostgreSQL 18, the way the db_deploy job does on
# Lakebase: twice as a non-superuser owner with CREATEROLE, CREATEDB and
# BYPASSRLS (what the deploy service principal has there), the second time on
# top of the first, then once as the postgres superuser into a second, fresh
# database (the template adopts no role another login holds ADMIN on, so the
# superuser cannot take over the first database's roles). A superuser hides
# ordering mistakes such as granting a role after it is needed; the first two
# runs catch them. Tests that switch login (SET SESSION AUTHORIZATION) need a
# superuser: they skip in the first two runs, as on Lakebase, and run in the
# third. Parameters as on the demo, except env=dev (no admin password needed).
# Between the first two runs and after the second, the db_deploy job's
# provisioning (jobs/patch_desk_job.py provision-principals) maps local
# people and must survive the redeploy on top
# (jobs/tests/test_provision_principals_db.py). Then the app's data layer
# (app/db.py) submits, lists and decides over the REST routes as those
# people's own logins (app/tests/test_db_routes.py), and the export job's
# routines read and mark the patch it approved (jobs/tests/test_export_db.py).
# Needs docker, pgmi and uv. Usage: db/local-check.sh [port]
set -euo pipefail

port="${1:-55440}"
name="lakebase-apps-local-check"
db="lakebase_apps_check"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
params=(
  --param env=dev
  --param 'provider_role_pattern=databricks\_%'
  --param 'provider_schemas=["__db_system"]'
  --param 'oidc_issuers=["https://idp.example.com/oidc"]'
)

cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
docker run -d --name "$name" -e POSTGRES_PASSWORD=local -p "127.0.0.1:$port:5432" postgres:18 >/dev/null
for _ in $(seq 1 60); do
  docker exec "$name" pg_isready -U postgres -q && break
  sleep 1
done
sleep 1
docker exec "$name" psql -U postgres -q -c \
  "CREATE ROLE deployer LOGIN PASSWORD 'local' CREATEROLE CREATEDB BYPASSRLS"

# provision PHASE: the provisioning test for that phase must run and pass.
provision() {
  local log
  log="$(cd "$repo" && PATCH_DESK_DB_URL="postgresql://deployer:local@127.0.0.1:$port/$db" \
    uv run --quiet --no-project --with pytest --with-requirements app/requirements.txt \
    pytest -q -p no:cacheprovider -k "$1" jobs/tests/test_provision_principals_db.py 2>&1)" \
    || { printf '%s\n' "$log" >&2; echo "error: provisioning ($1) failed" >&2; exit 1; }
  printf '%s\n' "$log" | tail -1
  grep -qE '^1 passed' <<<"$(printf '%s\n' "$log" | tail -1)" \
    || { echo "error: provisioning ($1) did not run" >&2; exit 1; }
}

skipped="skipped: (separate|patch desk) logins need a superuser deploy"
for run in 1 2; do
  echo "== deploy $run as the non-superuser owner (fresh database, then on top of it)"
  PGMI_CONNECTION_STRING="postgresql://deployer:local@127.0.0.1:$port/postgres?sslmode=disable" \
    pgmi deploy "$here" -d "$db" "${params[@]}" --force
  if (( run == 1 )); then
    echo "== provisioning: people mapped, moved and removed"
    provision fresh
  else
    echo "== provisioning after the redeploy: nothing to change"
    provision redeployed
    echo "== the app's data layer as the people's own logins"
    applog="$(cd "$repo" && PATCH_DESK_DB_URL="postgresql://deployer:local@127.0.0.1:$port/$db" \
      uv run --quiet --no-project --with pytest --with-requirements app/requirements.txt \
      pytest -q -p no:cacheprovider app/tests/test_db_routes.py 2>&1)" \
      || { printf '%s\n' "$applog" >&2; echo "error: app data layer test failed" >&2; exit 1; }
    printf '%s\n' "$applog" | tail -1
    grep -qE '^3 passed' <<<"$(printf '%s\n' "$applog" | tail -1)" \
      || { echo "error: app data layer test did not run" >&2; exit 1; }
    echo "== the export job's routines on the approved patch the app left"
    exportlog="$(cd "$repo" && PATCH_DESK_DB_URL="postgresql://deployer:local@127.0.0.1:$port/$db" \
      uv run --quiet --no-project --with pytest --with-requirements app/requirements.txt \
      pytest -q -p no:cacheprovider jobs/tests/test_export_db.py 2>&1)" \
      || { printf '%s\n' "$exportlog" >&2; echo "error: export test failed" >&2; exit 1; }
    printf '%s\n' "$exportlog" | tail -1
    grep -qE '^1 passed' <<<"$(printf '%s\n' "$exportlog" | tail -1)" \
      || { echo "error: export test did not run" >&2; exit 1; }
  fi
done

echo "== deploy 3 as the postgres superuser into a fresh database: the login tests run"
out="$(mktemp)"
trap 'cleanup; rm -f "$out"' EXIT
PGMI_CONNECTION_STRING="postgresql://postgres:local@127.0.0.1:$port/postgres?sslmode=disable" \
  pgmi deploy "$here" -d "${db}_superuser" "${params[@]}" --force 2>&1 | tee "$out"
for t in test_separate_logins test_patch_logins; do
  grep -q "\[pgmi\] Test: ./api/__test__/database_logins/$t.sql" "$out" \
    || { echo "error: database_logins/$t.sql did not run" >&2; exit 1; }
done
if grep -qE "$skipped" "$out"; then
  echo "error: the login tests were skipped in the superuser run" >&2
  exit 1
fi
echo "login tests ran as superuser (not skipped)"
echo "local check passed"
