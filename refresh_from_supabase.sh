#!/usr/bin/env bash
# Build a NORMALIZED copy of Supabase's CURRENT data in a NEW, EMPTY Postgres database,
# using the repo's own scripts (load_canonical.py + docs/db-normalization + docs/db-migrations).
# Nothing here touches your live Railway database. Check the result first, then decide how to swap it in.
#
# Run from the repo root (HR_ARIBA-main/):
#   pip install "psycopg[binary]"
#   SUPABASE_URL="postgresql://postgres:PASSWORD@db.xxxx.supabase.co:5432/postgres" \
#   TARGET_URL="postgresql://postgres:PASSWORD@HOST:PORT/ariba_rebuild" \
#   bash refresh_from_supabase.sh
#
# TARGET_URL must be a brand-new empty database (local Postgres, or a new database on the Railway Postgres
# reached through DATABASE_PUBLIC_URL). pg_dump must be the same version as Supabase's Postgres or newer.
set -euo pipefail

: "${SUPABASE_URL:?set SUPABASE_URL}"
: "${TARGET_URL:?set TARGET_URL (a NEW empty database, not production)}"
N=docs/db-normalization
M=docs/db-migrations
[ -f "$N/ariba_normalization.sql" ] || { echo "Run this from the repo root."; exit 1; }

P() { psql "$TARGET_URL" -X -q -v ON_ERROR_STOP=1 "$@"; }

if [ "$(P -At -c "select count(*) from information_schema.tables where table_schema='public'")" != "0" ]; then
  echo "TARGET_URL is not empty. Create a fresh database and try again."; exit 1
fi

echo "== 1/5 dump Supabase (read-only)"
pg_dump "$SUPABASE_URL" --schema=public --no-owner --no-privileges -f supabase_canonical.sql
tail -5 supabase_canonical.sql | grep -q "PostgreSQL database dump complete" || { echo "Dump incomplete, stopping."; exit 1; }

echo "== 2/5 load the tables and rows into the empty database"
CANONICAL_TARGET_URL="$TARGET_URL" "${PYTHON:-python3}" backend/tools/load_canonical.py supabase_canonical.sql

echo "== 3/5 restore keys, run checks, apply fixes"
P -f "$N/railway_prep.sql"
echo "-- preflight BEFORE fixes:"; P -f "$N/preflight_checks.sql"
P -f "$N/pre_migration_fixes.sql"
echo "-- preflight AFTER fixes (anything left over that matters will stop step 4 with a clear error):"
P -f "$N/preflight_checks.sql"

echo "== 4/5 normalize the schema"
P -f "$N/ariba_normalization.sql"

echo "== 5/5 React-port tables (docs/db-migrations)"
for f in "$M"/0[0-9][0-9]_*.sql; do
  echo "-- $(basename "$f")"
  P -f "$f"
  v="$M/verify_$(basename "$f" | cut -c1-3).sql"
  if [ -f "$v" ]; then
    out="$(P -At -F ' | ' -f "$v")"
    echo "$out" | sed 's/^/   /'
    if echo "$out" | grep -q '| FAIL'; then echo "Verification failed, stopping."; exit 1; fi
  fi
done

echo "== done. Row counts in the rebuilt database:"
P -At -F ' = ' -c "select 'employees', count(*) from employee_directory
  union all select 'accounts', count(*) from ariba_auth_accounts
  union all select 'workflow_requests', count(*) from workflow_requests
  union all select 'leave_requests', count(*) from leave_requests
  union all select 'attendance', count(*) from attendance
  union all select 'payrolls', count(*) from employee_payrolls
  union all select 'documents', count(*) from ariba_documents"
