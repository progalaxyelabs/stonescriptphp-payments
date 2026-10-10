#!/usr/bin/env bash
# L7.3: the PHP order service, the webhook -> pay_apply_capture processor and the operator path,
# run against the REAL SQL functions on a throwaway database (see tests/shell/l7_2_webhook_inbox.sh
# for the PAY_PHP_IMAGE / PAY_VENDOR_DIR / PAY_FRAMEWORK_DIR / PAY_DB_* contract).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${PAY_PHP_IMAGE:-}" ]; then
  echo "!! PAY_PHP_IMAGE is not set: the real-SQL PHP tests cannot run (build tests/docker/php-pg.Dockerfile)." >&2; exit 1
fi
DB=paytest_l73_php
echo "== L7.3 orders + capture through PHP against real SQL"
new_db $DB
load_schema $DB || { fail "schema load"; finish "L7.3 php"; exit 1; }
activate_gateways $DB
widen_issue_window $DB

HOST="${PAY_DB_HOST:-127.0.0.1}"; PORT="${PAY_DB_PORT:-5432}"; USER_="${PAY_DB_USER:-postgres}"; DBPASS="${PAY_DB_PASSWORD:-}"
VENDOR="${PAY_VENDOR_DIR:-$ROOT/vendor}"
MOUNTS=(-v "$ROOT":/app -v "$VENDOR":/app/vendor:ro)
[ -n "${PAY_FRAMEWORK_DIR:-}" ] && MOUNTS+=(-v "$PAY_FRAMEWORK_DIR":/StoneScriptPHP:ro)
OUT=$(docker run --rm --network host "${MOUNTS[@]}" -w /app \
  -e "PAYMENTS_TEST_PG_DSN=pgsql:host=$HOST;port=$PORT;dbname=$DB;user=$USER_;password=$DBPASS" \
  "$PAY_PHP_IMAGE" vendor/bin/phpunit --do-not-cache-result --filter OrdersPostgresTest 2>&1)
RC=$?
echo "$OUT" | tail -6 | sed 's/^/    /'
check "phpunit (real SQL) exited cleanly" "0" "$RC"
check "no real-SQL test was skipped" "0" "$(echo "$OUT" | grep -ciE 'skipped')"
drop_db $DB
finish "L7.3 php"
