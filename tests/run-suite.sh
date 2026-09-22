#!/usr/bin/env bash
# stonescriptphp-pay :: SQL test-suite / schema-deploy runner.
#
# Loads the module's SQL into a database in the ONE canonical order (numeric
# filename prefix, ascending, across every src/**/*.pgsql — bucketed
# tables/functions/seeders/types for every feature — and tests/sql/*.psql),
# then reports the differential-golden tally.
#
#   Deployable schema  (src/**/*.pgsql) runs with ON_ERROR_STOP=1
#                       — a real DDL/function error MUST abort.
#   Test + demo suite  (tests/sql/*.psql)           runs with ON_ERROR_STOP=0
#                       — assertions LOG (never abort); by-design ER* negative
#                       cases are expected to raise.
#
# Usage:
#   PSQL='psql -h localhost -U postgres' DB=payments_suite ./tests/run-suite.sh
#   ./tests/run-suite.sh --schema-only          # deploy the schema only, no tests
#
# PSQL defaults to "psql"; DB defaults to "payments_suite".
#
# ⚠️ DATABASE-LIFECYCLE SAFETY (a real data-loss bug, fixed 2026-09-22):
#   Full test-suite mode (no --schema-only) is a THROWAWAY differential-golden
#   run — it DROPs and recreates $DB fresh every time, on purpose. Never point
#   it at anything you care about.
#   --schema-only mode is documented (LOAD-ORDER.md) as the DEPLOY recipe —
#   i.e. it is meant to be run against a real, already-provisioned target
#   database (in a StoneScriptPHP project this is the StoneScriptDB Gateway
#   migration path). It therefore NEVER drops or creates $DB — it only loads
#   into whatever database already exists at that name, and fails loudly if
#   it doesn't. The DROP/CREATE block below previously ran unconditionally
#   BEFORE the --schema-only branch was even evaluated, so following this
#   script's own documented deploy recipe against a real database name (e.g.
#   DB=payments_prod, straight from the old LOAD-ORDER.md example) silently
#   destroyed it. Do not reintroduce a DROP/CREATE in the --schema-only path.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSQL="${PSQL:-psql}"
DB="${DB:-payments_suite}"
SCHEMA_ONLY=0; [ "${1:-}" = "--schema-only" ] && SCHEMA_ONLY=1

# canonical order = sort by basename prefix (src file sorts before its _demo companion)
schema_files=$(find "$ROOT/src" -name '*.pgsql' | awk -F/ '{print $NF"\t"$0}' | sort | cut -f2-)
if [ "$SCHEMA_ONLY" = 1 ]; then
  files="$schema_files"
  # Deploy target: must already exist. Never drop/create here — see the
  # safety note above.
  if ! $PSQL -d "$DB" -tAc "SELECT 1" > /dev/null 2>&1; then
    echo "!! database \"$DB\" is not reachable/does not exist. --schema-only deploys INTO an" >&2
    echo "!! already-provisioned database (never creates or drops one) — provision it first" >&2
    echo "!! (e.g. via the StoneScriptDB Gateway), then re-run." >&2
    exit 1
  fi
else
  files=$( { find "$ROOT/src" -name '*.pgsql'; find "$ROOT/tests/sql" -name '*.psql'; } \
           | awk -F/ '{print $NF"\t"$0}' | sort | cut -f2- )
  # Throwaway test run only: fresh DB every time, by design.
  $PSQL -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB" || exit 1
fi

rc_all=0
while IFS= read -r f; do
  case "$f" in */src/*) oes=1 ;; *) oes=0 ;; esac
  echo ">> $(basename "$f")  (ON_ERROR_STOP=$oes)"
  $PSQL -v ON_ERROR_STOP=$oes -d "$DB" -q -f "$f" || { [ "$oes" = 1 ] && { echo "!! schema load aborted"; rc_all=1; break; }; }
done <<< "$files"

if [ "$SCHEMA_ONLY" = 0 ] && [ "$rc_all" = 0 ]; then
  echo "=== DIFFERENTIAL GOLDEN TALLY (expect failed = 0) ==="
  $PSQL -d "$DB" -c "SELECT count(*) total, count(*) FILTER (WHERE passed) passed, count(*) FILTER (WHERE NOT passed) failed FROM _inv_diff_results;"
  $PSQL -d "$DB" -tAc "SELECT label,actual,expected FROM _inv_diff_results WHERE NOT passed;"
fi
exit $rc_all
