#!/usr/bin/env bash
# L7.2 acceptance beyond a single session:
#   * concurrent redelivery of ONE event id stores exactly one row and exactly one caller sees "new"
#   * concurrent claims of ONE row: exactly one worker wins the lease
#   * 1000 distinct events recorded concurrently: 1000 rows, no loss
#   * the PHP ingress + replayer against the REAL SQL functions and real Razorpay signature checks
#
# Needs: PGBENCH (see tests/shell/l7_1_numbering.sh) and, for the PHP part, a docker image of PHP
# with pdo_pgsql in PAY_PHP_IMAGE (build tests/docker/php-pg.Dockerfile), plus:
#   PAY_VENDOR_DIR     a composer vendor dir with phpunit (default $ROOT/vendor)
#   PAY_FRAMEWORK_DIR  the StoneScriptPHP checkout the vendor dir's progalaxyelabs/stonescriptphp
#                      symlink points at, mounted at /StoneScriptPHP (only needed if vendor symlinks it)
#   PAY_DB_HOST/PAY_DB_PORT/PAY_DB_USER/PAY_DB_PASSWORD  how the PHP container reaches the same server
#                      as PSQL (defaults 127.0.0.1 / 5432 / postgres / empty; the container runs --network host)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${PGBENCH:-}" ]; then
  if command -v pgbench >/dev/null 2>&1; then PGBENCH="pgbench"; else
    echo "!! PGBENCH is not set and pgbench is not on PATH: the concurrency proofs cannot run." >&2; exit 1
  fi
fi
if [ -z "${PAY_PHP_IMAGE:-}" ]; then
  echo "!! PAY_PHP_IMAGE is not set: the real-SQL PHP tests cannot run (build tests/docker/php-pg.Dockerfile)." >&2; exit 1
fi

DB=paytest_l72
echo "== L7.2 webhook inbox: concurrency + PHP against real SQL"
new_db $DB
load_schema $DB || { fail "schema load"; finish "L7.2"; exit 1; }

run_bench() { # run_bench <clients> <txns> <script>
  local out; out=$($PGBENCH -n -c "$1" -j 4 -t "$2" -f /dev/stdin $DB <<< "$3" 2>&1); BENCH_RC=$?
  BENCH_OUT="$out"
  echo "$out" | grep -E "number of transactions actually processed|number of failed transactions" | sed 's/^/    /'
}

q $DB "CREATE TABLE t_new (n int); CREATE TABLE t_claimed (n int);" >/dev/null

echo "-- 200 concurrent deliveries of the SAME event id"
run_bench 50 4 "SELECT o_is_new AS isnew FROM pay_webhook_record('razorpay', 'evt_same', 'payment.captured', 'p', '{\"a\":1}', '{}', NULL) \\gset
\\if :isnew
INSERT INTO t_new VALUES (1);
\\endif"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "exactly one inbox row" "1" "$(q $DB "SELECT count(*) FROM pay_webhook_inbox WHERE event_id = 'evt_same'")"
check "exactly one caller was told the event is new" "1" "$(q $DB "SELECT count(*) FROM t_new")"

echo "-- 100 concurrent claims of ONE row"
q $DB "SELECT o_id FROM pay_webhook_record('razorpay', 'evt_claim', 'payment.captured', 'p', '{}', '{}', NULL)" >/dev/null
CID=$(q $DB "SELECT id FROM pay_webhook_inbox WHERE event_id = 'evt_claim'")
run_bench 50 2 "SELECT count(*) AS got FROM pay_webhook_claim($CID) \\gset
\\if :got > 0
INSERT INTO t_claimed VALUES (1);
\\endif"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "exactly one worker won the lease" "1" "$(q $DB "SELECT count(*) FROM t_claimed")"
check "the row counts a single attempt" "1" "$(q $DB "SELECT attempts FROM pay_webhook_inbox WHERE id = $CID")"

echo "-- 1000 distinct events recorded by 40 concurrent clients"
run_bench 40 25 "\\set n random(1, 1000000000)
SELECT o_id FROM pay_webhook_record('razorpay', 'evt_distinct_' || :client_id || '_' || :n, 'payment.captured', 'p', '{}', '{}', NULL);"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "every distinct event stored (no loss)" "1000" "$(q $DB "SELECT count(*) FROM pay_webhook_inbox WHERE event_id LIKE 'evt_distinct_%'")"

echo "-- PHP ingress + replayer against the real SQL"
HOST="${PAY_DB_HOST:-127.0.0.1}"; PORT="${PAY_DB_PORT:-5432}"; USER_="${PAY_DB_USER:-postgres}"; DBPASS="${PAY_DB_PASSWORD:-}"
VENDOR="${PAY_VENDOR_DIR:-$ROOT/vendor}"
MOUNTS=(-v "$ROOT":/app -v "$VENDOR":/app/vendor:ro)
[ -n "${PAY_FRAMEWORK_DIR:-}" ] && MOUNTS+=(-v "$PAY_FRAMEWORK_DIR":/StoneScriptPHP:ro)
OUT=$(docker run --rm --network host "${MOUNTS[@]}" -w /app \
  -e "PAYMENTS_TEST_PG_DSN=pgsql:host=$HOST;port=$PORT;dbname=$DB;user=$USER_;password=$DBPASS" \
  "$PAY_PHP_IMAGE" vendor/bin/phpunit --do-not-cache-result --filter WebhookInboxPostgresTest 2>&1)
RC=$?
echo "$OUT" | tail -6 | sed 's/^/    /'
check "phpunit (real SQL) exited cleanly" "0" "$RC"
check "no real-SQL test was skipped" "0" "$(echo "$OUT" | grep -ciE 'skipped')"

drop_db $DB
finish "L7.2 webhook inbox"
