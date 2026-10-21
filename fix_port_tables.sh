#!/usr/bin/env bash
# Finish the rebuild when Supabase already has OLDER versions of the React-port tables
# (candidates, candidate files/invites, manager perms, doc signing, mail accounts, tasks, ...).
#
# 1. moves the old-layout tables to schema ops (renamed old_*), nothing is deleted
# 2. runs docs/db-migrations/001_react_port.sql, which now creates the new tables
# 3. verifies it
# 4. copies the old rows into the new layout and prints old vs new row counts
#
# Run from the repo root, in the same Git Bash window where TARGET_URL is set to the ariba_rebuild database:
#   bash fix_port_tables.sh
set -euo pipefail

: "${TARGET_URL:?set TARGET_URL (the ariba_rebuild database, NOT the live one)}"
export PGCLIENTENCODING=UTF8
M=docs/db-migrations
[ -f "$M/001_react_port.sql" ] || { echo "Run this from the repo root."; exit 1; }

P() { psql "$TARGET_URL" -X -q -v ON_ERROR_STOP=1 "$@"; }

echo "== 1/4 move the old-layout tables aside (ops.old_*)"
P <<'SQL'
BEGIN;
CREATE SCHEMA IF NOT EXISTS ops;
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ariba_candidates','ariba_candidate_files','ariba_candidate_invites','ariba_targets',
    'ariba_evaluations','ariba_delegations','ariba_manager_perms','ariba_doc_signing','ariba_mail_accounts','ariba_tasks']
  LOOP
    -- only move a table that is still the old one (safe to run again)
    IF to_regclass('public.' || t) IS NOT NULL AND to_regclass('ops.old_' || t) IS NULL THEN
      EXECUTE format('ALTER TABLE public.%I SET SCHEMA ops', t);
      EXECUTE format('ALTER TABLE ops.%I RENAME TO %I', t, 'old_' || t);
    END IF;
  END LOOP;
END $$;
COMMIT;
SQL

echo "== 2/4 create the new tables (001_react_port.sql)"
P -f "$M/001_react_port.sql"

echo "== 3/4 verify"
out="$(P -At -F ' | ' -f "$M/verify_001.sql")"
echo "$out" | sed 's/^/   /'
if echo "$out" | grep -q '| FAIL'; then echo "Verification failed, stopping."; exit 1; fi

echo "== 4/4 copy the old rows into the new layout"
P <<'SQL'
BEGIN;

-- candidates (the e-mail column is now generated from data)
INSERT INTO ariba_candidates (id, ref_token, data, status, submitted_at, reviewed_by, reviewed_at, review_note, employee_id)
SELECT o.id, o.ref_token, o.data::jsonb, o.status, coalesce(o.submitted_at, now()), o.reviewed_by, o.reviewed_at, o.review_note,
       (SELECT d.employee_id FROM employee_directory d WHERE d.employee_id = o.employee_id)
FROM ops.old_ariba_candidates o;

-- candidate files: doc_type -> file_type (a document type that does not exist yet is added)
INSERT INTO document_types (code, name_ar)
SELECT DISTINCT o.doc_type, o.doc_type FROM ops.old_ariba_candidate_files o
WHERE o.doc_type IS NOT NULL AND NOT EXISTS (SELECT 1 FROM document_types t WHERE t.code = o.doc_type);
INSERT INTO ariba_candidate_files (id, candidate_id, file_type, file_name, mime_type, file_data, created_at)
SELECT o.id, c.id, coalesce(o.doc_type, 'other'), o.file_name, coalesce(o.mime_type, 'application/octet-stream'),
       o.file_data, coalesce(o.created_at, now())
FROM ops.old_ariba_candidate_files o
JOIN ariba_candidates c ON c.id::text = o.candidate_id::text;

-- invites (an invite with no expiry becomes already expired)
INSERT INTO ariba_candidate_invites (token, label, created_by, created_at, expires_at, opened_at, used_at, revoked_at, candidate_id)
SELECT o.token, o.label, o.created_by, coalesce(o.created_at, now()), coalesce(o.expires_at, o.created_at, now()),
       o.opened_at, o.used_at, o.revoked_at,
       (SELECT c.id FROM ariba_candidates c WHERE c.id::text = o.candidate_id::text)
FROM ops.old_ariba_candidate_invites o;

-- manager permissions
INSERT INTO ariba_manager_perms (manager_id, perms, updated_by, updated_at)
SELECT o.manager_id, coalesce(o.perms::jsonb, '{}'::jsonb), o.updated_by, coalesce(o.updated_at, now())
FROM ops.old_ariba_manager_perms o
WHERE EXISTS (SELECT 1 FROM employee_directory d WHERE d.employee_id = o.manager_id);

-- document signing (mgr_signed_by is not kept in the new layout)
INSERT INTO ariba_doc_signing (request_id, document_id, employee_id, manager_id, stage, needs_manager,
                               emp_signed_at, mgr_signed_at, reject_reason, updated_at)
SELECT w.id,
       (SELECT d.id FROM ariba_documents d WHERE d.id::text = o.document_id::text),
       o.employee_id,
       (SELECT e.employee_id FROM employee_directory e WHERE e.employee_id = o.manager_id),
       o.stage, coalesce(o.needs_manager, false), coalesce(o.emp_signed_at, now()), o.mgr_signed_at,
       o.reject_reason, coalesce(o.updated_at, now())
FROM ops.old_ariba_doc_signing o
JOIN workflow_requests w ON w.id::text = o.request_id::text
WHERE EXISTS (SELECT 1 FROM employee_directory e WHERE e.employee_id = o.employee_id);

-- mail accounts: the password is NOT copied (the app stores it encrypted); enter it again in Settings
INSERT INTO ariba_mail_accounts (owner, provider, host, port, secure, username, from_name, from_email, updated_at)
SELECT o.owner, 'smtp', o.host, o.port, coalesce(o.secure, true), o.username, o.from_name, o.from_email,
       coalesce(o.updated_at, now())
FROM ops.old_ariba_mail_accounts o;

-- tasks and meetings
INSERT INTO ariba_tasks (id, batch_id, kind, title, details, due_date, start_at, end_at, location, created_by,
                         assignee_id, status, response_note, created_at, updated_at)
SELECT o.id, gen_random_uuid(), o.kind, o.title, o.details, o.due_date, o.start_at, o.end_at, o.location,
       o.from_employee_id, o.to_employee_id, o.status, o.response_note, coalesce(o.created_at, now()), coalesce(o.updated_at, now())
FROM ops.old_ariba_tasks o
WHERE EXISTS (SELECT 1 FROM employee_directory e WHERE e.employee_id = o.from_employee_id)
  AND EXISTS (SELECT 1 FROM employee_directory e WHERE e.employee_id = o.to_employee_id);

-- old vs new row counts: every pair should match
SELECT t AS "table", old_rows, new_rows, CASE WHEN old_rows = new_rows THEN 'ok' ELSE 'CHECK' END AS result FROM (
  SELECT 'candidates' t, (SELECT count(*) FROM ops.old_ariba_candidates) old_rows, (SELECT count(*) FROM ariba_candidates) new_rows
  UNION ALL SELECT 'candidate_files', (SELECT count(*) FROM ops.old_ariba_candidate_files), (SELECT count(*) FROM ariba_candidate_files)
  UNION ALL SELECT 'candidate_invites', (SELECT count(*) FROM ops.old_ariba_candidate_invites), (SELECT count(*) FROM ariba_candidate_invites)
  UNION ALL SELECT 'manager_perms', (SELECT count(*) FROM ops.old_ariba_manager_perms), (SELECT count(*) FROM ariba_manager_perms)
  UNION ALL SELECT 'doc_signing', (SELECT count(*) FROM ops.old_ariba_doc_signing), (SELECT count(*) FROM ariba_doc_signing)
  UNION ALL SELECT 'mail_accounts', (SELECT count(*) FROM ops.old_ariba_mail_accounts), (SELECT count(*) FROM ariba_mail_accounts)
  UNION ALL SELECT 'tasks', (SELECT count(*) FROM ops.old_ariba_tasks), (SELECT count(*) FROM ariba_tasks)
  UNION ALL SELECT 'targets', (SELECT count(*) FROM ops.old_ariba_targets), (SELECT count(*) FROM ariba_targets)
  UNION ALL SELECT 'evaluations', (SELECT count(*) FROM ops.old_ariba_evaluations), (SELECT count(*) FROM ariba_evaluations)
  UNION ALL SELECT 'delegations', (SELECT count(*) FROM ops.old_ariba_delegations), (SELECT count(*) FROM ariba_delegations)
) x;

-- the old mail table holds the sending password in plain text: remove this copy (the original stays on Supabase)
DROP TABLE ops.old_ariba_mail_accounts;
COMMIT;
SQL

echo "== done. Re-enter the mail password in the app's Settings."
