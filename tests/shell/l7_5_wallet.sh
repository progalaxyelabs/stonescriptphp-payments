#!/usr/bin/env bash
# L7.5 acceptance that needs real concurrency (pgbench; see tests/shell/l7_1_numbering.sh for PGBENCH):
#   * 100 concurrent drains against a wallet that can pay for only 60 of them: exactly 60 apply, 40 are refused 'insufficient', the balance
#     ends at exactly zero and never goes negative; every tick id applies once
#   * the same tick id delivered 200 times by 50 clients debits once
#   * the same capture's top-up credited 200 times by 50 clients credits once
#   * drains, grants and expiry sweeps racing each other leave a ledger that verifies clean
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${PGBENCH:-}" ]; then
  if command -v pgbench >/dev/null 2>&1; then PGBENCH="pgbench"; else
    echo "!! PGBENCH is not set and pgbench is not on PATH: the concurrency proofs cannot run." >&2; exit 1
  fi
fi

DB=paytest_l75
echo "== L7.5 wallet v2: concurrency"
new_db $DB
load_schema $DB || { fail "schema load"; finish "L7.5"; exit 1; }
activate_gateways $DB
widen_issue_window $DB

run_bench() { # run_bench <clients> <txns> <script>
  local out; out=$($PGBENCH -n -c "$1" -j 4 -t "$2" -f /dev/stdin $DB <<< "$3" 2>&1); BENCH_RC=$?
  BENCH_OUT="$out"
  echo "$out" | grep -E "number of transactions actually processed|number of failed transactions" | sed 's/^/    /'
}

q $DB "
INSERT INTO pricing_plans (id, name, is_subscription, is_active, is_trial, created_at, created_by) VALUES (1, 'Wallet', false, true, false, '2026-01-01', 'seed');
INSERT INTO wlt_packs (id, pricing_plan_id, name, credits_milli, created_by) VALUES (1, 1, 'Ten credits', 10000, 'seed');
CREATE TABLE t_out (tag TEXT, outcome TEXT);
CREATE FUNCTION w_try(p_tag TEXT, p_tenant UUID, p_key TEXT, p_milli BIGINT) RETURNS VOID AS \$\$
DECLARE v_out TEXT;
BEGIN
    BEGIN
        SELECT o_outcome INTO v_out FROM wallet_drain(p_tenant, 'wplat', p_key, p_milli, '2026-10-10 10:00+05:30', 'bench', 'bench');
    EXCEPTION WHEN OTHERS THEN
        v_out := 'refused:' || SQLSTATE;
    END;
    INSERT INTO t_out VALUES (p_tag, v_out);
END; \$\$ LANGUAGE plpgsql;
" >/dev/null || { fail "fixtures"; finish "L7.5"; exit 1; }

W1=00000000-0000-0000-0000-0000000b0001
W2=00000000-0000-0000-0000-0000000b0002
W3=00000000-0000-0000-0000-0000000b0003
W4=00000000-0000-0000-0000-0000000b0004

# ---- 1. hard stop under contention ----
q $DB "SELECT _wlt_grant_free('$W1'::uuid, 'wplat', 'seed-a', 20000, '2026-10-01', '2026-12-01', 'bench', 'seed'), _wlt_grant_free('$W1'::uuid, 'wplat', 'seed-b', 40000, '2026-10-01', NULL, 'bench', 'seed')" >/dev/null
echo "-- 100 concurrent drains of 1000 against a balance of 60000"
run_bench 50 2 "\\set k random(1, 2000000000)
SELECT w_try('race', '$W1', 'race-' || :k || '-' || :client_id || '-' || :scale, 1000);"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "exactly 60 drains applied" "60" "$(q $DB "SELECT count(*) FROM t_out WHERE tag='race' AND outcome='applied'")"
check "the other 40 were refused 'insufficient' (the hard stop)" "40" "$(q $DB "SELECT count(*) FROM t_out WHERE tag='race' AND outcome='insufficient'")"
check "the balance is exactly zero" "0" "$(q $DB "SELECT o_milli FROM wallet_balance('$W1'::uuid, 'wplat', '2026-10-10 11:00+05:30')")"
check "never negative: no grant below zero, 60 drain rows of 1000" "0,60,60000" "$(q $DB "SELECT (SELECT count(*) FROM wlt_grants WHERE remaining_milli < 0) || ',' || count(*) || ',' || sum(debited_milli) FROM wlt_drains")"
check "the earlier-expiring grant was consumed first (20000 from it, 40000 from the other)" "20000,40000" "$(q $DB "SELECT string_agg(s::text, ',' ORDER BY e) FROM (SELECT g.expires_at IS NULL AS e, sum(a.milli) s FROM wlt_drain_allocations a JOIN wlt_grants g ON g.id=a.grant_id GROUP BY 1) x")"
check "_ledger_verify is clean" "0" "$(q $DB "SELECT count(*) FROM _ledger_verify()")"

# ---- 2. one tick id, 200 deliveries ----
q $DB "SELECT _wlt_grant_free('$W2'::uuid, 'wplat', 'seed', 100000, '2026-10-01', NULL, 'bench', 'seed')" >/dev/null
echo "-- the same tick 200 times, 50 clients"
run_bench 50 4 "SELECT w_try('tick', '$W2', 'tick-same', 2500);"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "applied once, 199 already_applied" "1,199" "$(q $DB "SELECT (SELECT count(*) FROM t_out WHERE tag='tick' AND outcome='applied') || ',' || (SELECT count(*) FROM t_out WHERE tag='tick' AND outcome='already_applied')")"
check "debited once" "97500" "$(q $DB "SELECT o_milli FROM wallet_balance('$W2'::uuid, 'wplat', '2026-10-10 11:00+05:30')")"

# ---- 3. one capture, 200 top-up deliveries ----
q $DB "SELECT pay_record_captured_payment('razorpay', 'pay_race', 'ord_x', 49000, 'INR', 'success', '2026-10-10 10:00+05:30', 'bench', NULL)" >/dev/null
echo "-- the same capture's top-up 200 times, 50 clients"
run_bench 50 4 "SELECT count(*) FROM _wlt_topup('$W3'::uuid, 'wplat', 1, 49000, 'razorpay', 'pay_race', '2026-10-10 10:00+05:30', 'bench');"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "one grant, 10 credits" "1,10000" "$(q $DB "SELECT count(*) || ',' || max(granted_milli) FROM wlt_grants g JOIN wlt_wallets w ON w.id=g.wallet_id WHERE w.tenant_id='$W3'::uuid")"
check "one ledger posting for it" "1" "$(q $DB "SELECT count(*) FROM ledger_txns WHERE ref = 'cap:razorpay:pay_race'")"

# ---- 4. everything at once ----
q $DB "SELECT _wlt_grant_free('$W4'::uuid, 'wplat', 'seed', 50000, '2026-10-01', '2026-10-10 10:30+05:30', 'bench', 'seed')" >/dev/null
echo "-- drains, grants and expiry sweeps racing"
run_bench 30 20 "\\set k random(1, 2000000000)
\\set which random(1, 10)
SELECT CASE WHEN :which <= 6 THEN w_try('mix', '$W4', 'mix-' || :k || '-' || :client_id, 1 + (:k % 900))::text
            WHEN :which <= 8 THEN (SELECT o_outcome FROM _wlt_grant_free('$W4'::uuid, 'wplat', 'g-' || :k || '-' || :client_id, 500 + (:k % 900), '2026-10-10 10:00+05:30', CASE WHEN :k % 2 = 0 THEN '2026-10-10 10:30+05:30'::timestamptz END, 'bench', 'mix'))
            ELSE (SELECT count(*)::text FROM (SELECT _wlt_expire_one(d.o_wallet_id, '2026-10-10 10:45+05:30') FROM _wlt_expire_due('2026-10-10 10:45+05:30', 5) d) x) END;"
check "pgbench exited cleanly (no deadlock)" "0" "$BENCH_RC"
check "_ledger_verify is clean after the race" "0" "$(q $DB "SELECT count(*) FROM _ledger_verify()")"
check "conservation: granted = remaining + forfeited + consumed" "true" "$(q $DB "SELECT (sum(granted_milli) = sum(remaining_milli) + sum(forfeited_milli) + (SELECT coalesce(sum(milli),0) FROM wlt_drain_allocations))::text FROM wlt_grants")"
check "no overdraft anywhere" "0" "$(q $DB "SELECT count(*) FROM wlt_grants WHERE remaining_milli < 0")"

# ---- 5. many meters on one wallet, racing: each meter's total is exactly floor(total x rate) and the wallet never overdraws ----
W5=00000000-0000-0000-0000-0000000b0005
q $DB "SELECT _wlt_grant_free('$W5'::uuid, 'wplat', 'meter-seed', 50000000, '2026-10-01', NULL, 'bench', 'seed')" >/dev/null
echo "-- 30 meters, 40 ticks each, 30 concurrent clients on one wallet"
run_bench 30 40 "\\set m :client_id
SELECT count(*) FROM wallet_drain_cumulative('$W5'::uuid, 'wplat', 'vm-' || :m, 'tick-' || :scale || '-' || :client_id || '-' || (SELECT coalesce(max(id),0) FROM wlt_meter_ticks), 1 + (SELECT coalesce(max(cumulative),0) FROM wlt_meters WHERE meter_key = 'vm-' || :m), 17, 60, '2026-10-10 10:00+05:30', 'bench', 'bench');"
check "pgbench exited cleanly (no deadlock)" "0" "$BENCH_RC"
check "the race really metered: 30 meters, at least 600 ticks" "t" "$(q $DB "SELECT ((SELECT count(*) FROM wlt_meters) = 30 AND (SELECT count(*) FROM wlt_meter_ticks) >= 600)::text" | sed 's/true/t/')"
check "every meter's debit equals exactly floor(cumulative x 17 / 60)" "0" "$(q $DB "SELECT count(*) FROM wlt_meters WHERE debited_milli <> div(cumulative * 17, 60::numeric)::bigint")"
check "the books balance after the metering race" "0" "$(q $DB "SELECT count(*) FROM _ledger_verify()")"

drop_db $DB
finish "L7.5 wallet concurrency"
