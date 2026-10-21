# Database Rebuild and Deployment Runbook

**Project:** Ariba HR System  
**Updated:** 2026-10-21  
**Status:** Rebuilt database prepared; backend cutover **not confirmed**.

> This runbook is a summary of code changes. It does not certify live database contents, deployment status, or schema compatibility. Validate against the actual infrastructure before execution.

## 1. Overview

The system has a PostgreSQL database hosted on Railway. A rebuilt database named `ariba_rebuild` was populated with newer data from Supabase. The running backend is still connected to the prior Railway database.

The cutover occured during the last step of workflow which involved a change to the backend's `DATABASE_URL` environment variable, **not a code push**. Railway may redeploy the backend when the variable is applied and the service is back. Right now completeion is postponed until deployments are functioning normally.

## 2. Reported schema and migration state

- Previous checks reportedly returned `normalized = true` and `has_port_tables = true` for the current Railway database.
- The rebuilt database is reported to have the same normalized layout and React-port tables, populated from Supabase.
- **Not yet independently verified:** exact schema equivalence, row counts, foreign keys, constraints, data freshness, backend compatibility, and application smoke tests.

## 3. Repository files

| File | Purpose | Commit policy |
| --- | --- | --- |
| `supabase_canonical.sql` | Source export containing HR data | **Never commit.** Store securely outside the repository and remove local working copies when no longer needed. |
| `refresh_from_supabase.sh` | Data refresh helper | Optional; inspect for secrets, destructive commands and logging before committing. |
| `fix_port_tables.sh` | React-port table repair helper | Optional; review and test before committing. |
| `.gitignore` | Excludes sensitive/local artifacts | Commit the exclusion rules. |

Suggested location for reviewed helper scripts: `docs/db-normalization/`.

## 4. Pre-cutover checklist

- [ ] Confirm Railway incident is resolved and new deployments work.
- [ ] Capture a restorable backup of both the old and rebuilt databases; test restoration.
- [ ] Compare table definitions, indexes, primary/foreign keys, constraints and extensions.
- [ ] Reconcile row counts and key business records against the Supabase source.
- [ ] Decide whether a write freeze or final delta sync is needed to avoid missing new Supabase changes.
- [ ] Test a staging/local backend against `ariba_rebuild` using a secure connection.
- [ ] Confirm required app secrets and network access are present.
- [ ] Agree on a maintenance window, owner, rollback trigger and acceptance criteria.

## 5. Deployment / cutover

1. In Railway, locate the **backend service** and its `DATABASE_URL` variable.
2. Securely record the old value in an approved secret store; **do not paste it into issues, commits, or logs**.
3. Set `DATABASE_URL` to the **private/internal** PostgreSQL URL for the Railway Postgres service, targeting database `ariba_rebuild`. Use the actual host, username and secret supplied by Railway; do not hard-code a sample password.
4. Apply the change and deploy **only when Railway builds are operational**.
5. Check deployment health, backend logs, authentication and core HR screens.
6. Verify the application is reading the intended records from `ariba_rebuild`.
7. Record the deployment identifier, timestamp, validation results and responsible reviewer.

> Do not assume a URL change is instant or risk-free. Variable changes can trigger a redeployment.

## 6. Post-cutover validation

- [ ] Login and authorization / role-based access
- [ ] Employee directory and employee details
- [ ] Attendance and leave workflows
- [ ] Documents and other migrated HR records
- [ ] Writes and reads against the intended database
- [ ] Backend health checks, error rates and logs
- [ ] Data freshness and reconciliation results

Do not mark the migration complete until these tests pass.

## 7. Rollback

1. Stop or restrict writes if integrity is at risk.
2. Restore the previous `DATABASE_URL` in Railway.
3. Redeploy the backend once deployment functionality is available.
4. Re-run smoke tests and confirm reads/writes target the old database.
5. Reconcile any writes made to `ariba_rebuild` after cutover before discarding them. A URL rollback alone does **not** migrate those writes back.

Retain the old database until formal acceptance and the rollback window are complete.

## 8. Security / Git hygiene

Never commit real HR records, SQL dumps, `.env` files, tokens, connection strings, passwords or database exports. Ensure `.gitignore` includes the actual dump filename, but remember `.gitignore` does not untrack a file already added to Git.

```gitignore
# Sensitive HR exports and local credentials
supabase_canonical.sql
*.dump
.env
.env.*
!.env.example
```

Before committing:

```bash
git status --short
git ls-files --error-unmatch supabase_canonical.sql
```

The second command should report that the file is not tracked. If it is tracked, stop and follow the project's secret/data exposure remediation process; deleting it from the latest commit does not erase Git history.

## 9. Pending decisions

- Railway incident resolution and safe deployment window
- Confirmed schema/data comparison evidence
- Data freeze or final synchronization approach
- Owner of production cutover and sign-off
- Post-cutover verification and rollback deadline
