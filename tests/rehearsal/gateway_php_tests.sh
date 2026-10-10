#!/usr/bin/env bash
# Runs the real-SQL PHP tests (orders, capture path, webhook inbox) THROUGH a real StoneScriptDB Gateway's /call endpoint
# instead of straight over PDO, against a database the gateway itself created from this checkout's schema.
#
#   GATEWAY_URL=http://127.0.0.1:19001 ADMIN_TOKEN=... PSQL='psql ... (same server as the gateway)' WORK=/empty/scratch \
#   PAY_PHP_IMAGE=... PAY_VENDOR_DIR=... PAY_FRAMEWORK_DIR=... PAY_DB_HOST/PORT/USER/PASSWORD=... bash tests/rehearsal/gateway_php_tests.sh
#
# NEVER point it at a shared or production gateway (it creates a platform and a database and activates its test gateways).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../shell/lib.sh"
: "${GATEWAY_URL:?}" "${ADMIN_TOKEN:?}" "${WORK:?}" "${PAY_PHP_IMAGE:?}"
mkdir -p "$WORK"
P="gwphp$(date +%s)"
echo "== PHP real-SQL tests through the gateway ($(curl -s "$GATEWAY_URL/health" | jq -r .version)) platform=$P"

curl -s -o /dev/null -X POST "$GATEWAY_URL/platform/register" -H 'Content-Type: application/json' -d "{\"platform\":\"$P\"}"
TOKEN=$(curl -s -X POST "$GATEWAY_URL/admin/platform-token" -H 'Content-Type: application/json' -H "Authorization: Bearer $ADMIN_TOKEN" -d "{\"platform\":\"$P\"}" | jq -r .token)
mkdir -p "$WORK/s/postgresql/tables" "$WORK/s/postgresql/functions" "$WORK/s/postgresql/seeders" "$WORK/s/postgresql/types" "$WORK/s/postgresql/migrations"
for b in tables functions seeders types; do
  while IFS= read -r f; do cp "$f" "$WORK/s/postgresql/$b/"; done < <(find "$ROOT/src" -path "*/Schema/$b/*.pgsql")
done
tar -czf "$WORK/s.tgz" -C "$WORK/s" postgresql
curl -s -o /dev/null -X POST "$GATEWAY_URL/platform/$P/schema" -F schema_name=main -F "schema=@$WORK/s.tgz"
HTTP=$(curl -s -o "$WORK/create.json" -w '%{http_code}' -X POST "$GATEWAY_URL/admin/database/create" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "{\"platform\":\"$P\",\"schema_name\":\"main\"}")
check "create database through the gateway" 2xx "$(case $HTTP in 2??) echo 2xx;; *) echo "$HTTP $(cat "$WORK/create.json")";; esac)"
DB="${P}_main"
q "$DB" "UPDATE inv_gateways SET is_active = true" >/dev/null
widen_issue_window "$DB"

HOST="${PAY_DB_HOST:-127.0.0.1}"; PORT="${PAY_DB_PORT:-5432}"; USER_="${PAY_DB_USER:-postgres}"; DBPASS="${PAY_DB_PASSWORD:-}"
VENDOR="${PAY_VENDOR_DIR:-$ROOT/vendor}"
MOUNTS=(-v "$ROOT":/app -v "$VENDOR":/app/vendor:ro)
[ -n "${PAY_FRAMEWORK_DIR:-}" ] && MOUNTS+=(-v "$PAY_FRAMEWORK_DIR":/StoneScriptPHP:ro)
OUT=$(docker run --rm --network host "${MOUNTS[@]}" -w /app \
  -e "PAYMENTS_TEST_PG_DSN=pgsql:host=$HOST;port=$PORT;dbname=$DB;user=$USER_;password=$DBPASS" \
  -e "PAYMENTS_TEST_GATEWAY_URL=$GATEWAY_URL" -e "PAYMENTS_TEST_GATEWAY_PLATFORM=$P" -e "PAYMENTS_TEST_GATEWAY_SCHEMA=main" \
  "$PAY_PHP_IMAGE" vendor/bin/phpunit --do-not-cache-result --filter 'OrdersPostgresTest|WebhookInboxPostgresTest|RefundQueueMonitorPostgresTest' 2>&1)
RC=$?
echo "$OUT" | tail -25 | sed 's/^/    /'
check "phpunit through the gateway exited cleanly" "0" "$RC"
check "no real-SQL test was skipped" "0" "$(echo "$OUT" | grep -ciE 'skipped')"
finish "PHP through the gateway"
