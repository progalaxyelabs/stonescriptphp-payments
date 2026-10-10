#!/usr/bin/env bash
# Shared helpers for the multi-database / multi-process shell tests.
# Sourced, never executed. Required env: PSQL (e.g. "psql -h 127.0.0.1 -U postgres").
# Every database these tests create is a throwaway whose name starts with
# "paytest_"; the helpers refuse to drop anything else.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PSQL="${PSQL:-psql}"
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
PASS=0
FAIL=0

fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "  ok:   $*"; PASS=$((PASS + 1)); }

# check "<description>" "<expected>" "<actual>"
check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$2], got [$3])"; fi
}

q() { $PSQL -d "$1" -v ON_ERROR_STOP=1 -tAqc "$2"; }

new_db() {
  case "$1" in paytest_*) ;; *) echo "refusing non-paytest db name: $1" >&2; exit 2 ;; esac
  $PSQL -d postgres -v ON_ERROR_STOP=1 -qc "DROP DATABASE IF EXISTS $1" -c "CREATE DATABASE $1" >/dev/null
}

drop_db() {
  case "$1" in paytest_*) ;; *) echo "refusing non-paytest db name: $1" >&2; exit 2 ;; esac
  $PSQL -d postgres -qc "DROP DATABASE IF EXISTS $1" >/dev/null 2>&1
}

# schema_files [--no-seeders] -> newline separated, canonical order (basename prefix).
schema_files() {
  find "$ROOT/src" -name '*.pgsql' \
    | { if [ "${1:-}" = "--no-seeders" ]; then grep -v '/seeders/'; else cat; fi; } \
    | awk -F/ '{print $NF"\t"$0}' | sort | cut -f2-
}

# load_schema <db> [--no-seeders]
load_schema() {
  local db="$1"; shift
  local f
  while IFS= read -r f; do
    $PSQL -v ON_ERROR_STOP=1 -d "$db" -q -f "$f" >/dev/null || { echo "schema load failed at $f" >&2; return 1; }
  done < <(schema_files "$@")
}

# The package seeds its gateways INACTIVE (placeholder endpoints). Tests that route or settle
# through them activate them explicitly, in a throwaway database only.
activate_gateways() { q "$1" "UPDATE inv_gateways SET is_active = true" >/dev/null; }

# Tests issue documents dated across several financial years; widen the date window (a real deployment keeps it small).
widen_issue_window() {
  q "$1" "UPDATE inv_gst_config SET config_value = '36500' WHERE config_key IN ('issue_date_window_days_live', 'issue_date_window_days_test')" >/dev/null
  # simulated dates: the clock-skew bound and the late-apply grace are widened too (production keeps them tight)
  q "$1" "UPDATE pay_config SET config_value = '4000000000' WHERE config_key = 'pay_clock_skew_seconds'; UPDATE pay_config SET config_value = '100000000' WHERE config_key = 'ent_late_apply_grace_hours'" >/dev/null
}

finish() {
  echo "== $1: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
