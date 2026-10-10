#!/usr/bin/env bash
# L7.4 acceptance that needs real concurrency (pgbench; see tests/shell/l7_1_numbering.sh for PGBENCH):
#   * the same comp activation delivered 200 times by 50 clients extends once and writes one audit row
#   * 100 comps with DIFFERENT keys on one tenant, concurrently, stack exactly (+100 days) and write 100 audit rows
#   * 60 postpaid tenants billed by 20 concurrent billing runs: exactly 60 invoices, numbered exactly 1..60, one run row each
#   * the same capture 200 times: the entitlement is extended once; 20 different captures for one tenant stack exactly
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${PGBENCH:-}" ]; then
  if command -v pgbench >/dev/null 2>&1; then PGBENCH="pgbench"; else
    echo "!! PGBENCH is not set and pgbench is not on PATH: the concurrency proofs cannot run." >&2; exit 1
  fi
fi

DB=paytest_l74
echo "== L7.4 entitlement: concurrency"
new_db $DB
load_schema $DB || { fail "schema load"; finish "L7.4"; exit 1; }
activate_gateways $DB
widen_issue_window $DB

run_bench() { # run_bench <clients> <txns> <script>
  local out; out=$($PGBENCH -n -c "$1" -j 4 -t "$2" -f /dev/stdin $DB <<< "$3" 2>&1); BENCH_RC=$?
  BENCH_OUT="$out"
  echo "$out" | grep -E "number of transactions actually processed|number of failed transactions" | sed 's/^/    /'
}

q $DB "
SELECT _inv_issuer_upsert('e-issuer', 'eplat', NULL, 'Ent Pvt Ltd', 'regular', '29AAACX1234C1ZP', '29', 'Bengaluru', false, 'bench');
SELECT _inv_series_create('e-inv', 'e-issuer', 'invoice', 'live', 'EB', '/', 6, true, 'bench');
SELECT _inv_series_create('e-ord', 'e-issuer', 'invoice', 'live', 'EC', '/', 6, true, 'bench');
INSERT INTO pricing_plans (id, name, is_subscription, is_active, is_trial, created_at, created_by) VALUES
  (1, 'Monthly', true, true, false, '2026-01-01', 'seed'), (2, 'Postpaid', true, true, false, '2026-01-01', 'seed');
INSERT INTO subscription_pricing_plans (id, pricing_plan_id, duration, duration_uom, amount, is_amount_tax_exclusive, is_post_paid, is_active, created_at, created_by)
  VALUES (1, 1, 1, 'month', 49900, true, false, true, '2026-01-01', 'seed'), (2, 2, 1, 'month', 49900, true, true, true, '2026-01-01', 'seed');
CREATE TABLE t_out (tag TEXT, outcome TEXT);
CREATE FUNCTION e_try_comp(p_tag TEXT, p_tenant UUID, p_key TEXT, p_days INT) RETURNS VOID AS \$\$
DECLARE v_out TEXT;
BEGIN
    BEGIN
        SELECT o_outcome INTO v_out FROM _ent_comp_activate(p_tenant, 'eplat', 'default', 'comp-pro', p_days, p_key, 'bench', 'load test', '2026-10-01 10:00+05:30');
    EXCEPTION WHEN OTHERS THEN
        v_out := 'refused:' || SQLSTATE;
    END;
    INSERT INTO t_out VALUES (p_tag, v_out);
END; \$\$ LANGUAGE plpgsql;
CREATE FUNCTION e_try_capture(p_tag TEXT, p_txn TEXT, p_ref TEXT) RETURNS VOID AS \$\$
DECLARE v_out TEXT;
BEGIN
    BEGIN
        SELECT o_outcome INTO v_out FROM pay_apply_capture('razorpay', p_txn, p_ref, NULL, NULL, 58882, 'INR', 'live', '2026-10-01 10:00+05:30', 'bench', NULL, '2026-10-01 10:00+05:30');
    EXCEPTION WHEN OTHERS THEN
        v_out := 'refused:' || SQLSTATE;
    END;
    INSERT INTO t_out VALUES (p_tag, v_out);
END; \$\$ LANGUAGE plpgsql;
CREATE FUNCTION e_spec() RETURNS TEXT AS \$\$
    SELECT jsonb_build_object(
        'buyer', jsonb_build_object('legal_name', 'Buyer', 'registration_status', 'unregistered', 'address_state', 'Karnataka'),
        'billing_country_code', 'IN', 'billing_state', 'Karnataka', 'supply_type', 'domestic', 'price_is_inclusive', false, 'round_off', false, 'due_days', 0,
        'lines', jsonb_build_array(jsonb_build_object('description', 'Item', 'hsn_sac', '998314', 'quantity', '1', 'unit_price', '499.00', 'gst_rate', 0.18)))::text;
\$\$ LANGUAGE sql;
" >/dev/null || { fail "fixtures"; finish "L7.4"; exit 1; }

T1=00000000-0000-0000-0000-0000000f0001
T2=00000000-0000-0000-0000-0000000f0002
T3=00000000-0000-0000-0000-0000000f0003
T4=00000000-0000-0000-0000-0000000f0004

# ---- 1. one comp, 200 deliveries ----
echo "-- one comp activation, 200 deliveries, 50 clients"
run_bench 50 4 "SELECT e_try_comp('same', '$T1', 'comp-same', 30);"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "exactly one delivery applied it" "1" "$(q $DB "SELECT count(*) FROM t_out WHERE tag='same' AND outcome='applied'")"
check "every other delivery was already_applied" "199" "$(q $DB "SELECT count(*) FROM t_out WHERE tag='same' AND outcome='already_applied'")"
check "one audit row" "1" "$(q $DB "SELECT count(*) FROM ent_activations WHERE tenant_id='$T1'::uuid")"
check "extended once (30 days from 1 Oct 10:00 IST)" "2026-10-31 10:00:00+05:30" "$(q $DB "SET timezone='Asia/Kolkata'; SELECT current_period_end FROM ent_entitlements WHERE tenant_id='$T1'::uuid" | tail -1)"
check "no invoice, payment or number for a comp" "0,0" "$(q $DB "SELECT (SELECT count(*) FROM inv_invoices) || ',' || (SELECT count(*) FROM inv_payments)")"

# ---- 2. 100 comps with different keys stack exactly ----
echo "-- 100 comps, distinct keys, one tenant, 20 clients"
run_bench 20 5 "\\set k random(1, 2000000000)
SELECT e_try_comp('stack', '$T2', 'comp-' || :k || '-' || :client_id, 1);"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "all 100 applied" "100" "$(q $DB "SELECT count(*) FROM t_out WHERE tag='stack' AND outcome='applied'")"
check "100 audit rows" "100" "$(q $DB "SELECT count(*) FROM ent_activations WHERE tenant_id='$T2'::uuid")"
check "stacked exactly: start + 100 days" "2027-01-09 10:00:00+05:30" "$(q $DB "SET timezone='Asia/Kolkata'; SELECT current_period_end FROM ent_entitlements WHERE tenant_id='$T2'::uuid" | tail -1)"

# ---- 3. the billing run (one entitlement per transaction, the way the runner does it) ----
echo "-- 60 postpaid tenants, 20 concurrent runners (one entitlement per transaction, SKIP LOCKED)"
q $DB "SELECT _ent_enroll_postpaid(('00000000-0000-0000-0000-00000a' || lpad(g::text, 6, '0'))::uuid, 'eplat', 'default', 2,
        jsonb_build_object('series_code', 'e-inv', 'mode', 'live', 'billing_country_code', 'IN', 'billing_state', 'Karnataka', 'hsn_sac', '998314', 'gst_rate', 0.18,
                           'buyer', jsonb_build_object('legal_name', 'Post Buyer', 'registration_status', 'unregistered', 'address_state', 'Karnataka')),
        '2026-01-01 00:00+05:30', 'enroll-' || g, 'bench') FROM generate_series(1, 60) g" >/dev/null
check "60 enrolled" "60" "$(q $DB "SELECT count(*) FROM ent_entitlements WHERE billing_mode='postpaid'")"
run_bench 20 90 "SELECT count(*) FROM (SELECT o_entitlement_id FROM _ent_billing_due('2026-02-01 00:00+05:30', 1000) ORDER BY random() LIMIT 1) d, LATERAL _ent_billing_run_one(d.o_entitlement_id, '2026-02-01 00:00+05:30', 'bench') r;"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "exactly 60 invoices, one per tenant" "60,60" "$(q $DB "SELECT count(*) || ',' || count(DISTINCT tenant_id) FROM inv_invoices WHERE charge_source='postpaid_cycle'")"
check "one billing-run row per tenant" "60" "$(q $DB "SELECT count(*) FROM ent_billing_runs")"
check "numbers are exactly 1..60 (no gap, no duplicate)" "1,60,60" "$(q $DB "SELECT min(number_seq) || ',' || max(number_seq) || ',' || count(DISTINCT number_seq) FROM inv_invoices WHERE charge_source='postpaid_cycle'")"
check "the counter equals the number of invoices" "60" "$(q $DB "SELECT last_number FROM inv_series_counter c JOIN inv_series s ON s.id=c.series_id WHERE s.series_code='e-inv'")"
check "every tenant's next billing moved on by exactly one period" "60" "$(q $DB "SET timezone='Asia/Kolkata'; SELECT count(*) FROM ent_entitlements WHERE billing_mode='postpaid' AND next_billing_at = '2026-03-01 00:00+05:30'" | tail -1)"
echo "-- billing run racing the tick and payments"
run_bench 10 150 "SELECT count(*) FROM (SELECT o_entitlement_id FROM _ent_billing_due('2026-03-01 00:00+05:30', 1000) ORDER BY random() LIMIT 1) d, LATERAL _ent_billing_run_one(d.o_entitlement_id, '2026-03-01 00:00+05:30', 'bench') r; SELECT * FROM _ent_tick('2026-03-05 00:00+05:30', 50, 0);"
check "pgbench exited cleanly (no deadlock)" "0" "$BENCH_RC"
check "second month: 120 invoices in all, still unique and contiguous" "1,120,120" "$(q $DB "SELECT min(number_seq) || ',' || max(number_seq) || ',' || count(DISTINCT number_seq) FROM inv_invoices WHERE charge_source='postpaid_cycle'")"

# ---- 4. captures set the entitlement exactly once ----
mkorder() { # mkorder <tenant> <key>
  q $DB "SELECT o_order_ref FROM pay_order_create('$1'::uuid, 'eplat', '$2', 'subscription_period', '1', NULL, 58882, 'INR', 'razorpay', 'live', 'e-ord', e_spec(), 'bench')"
}
echo "-- the same capture 200 times"
O1=$(mkorder $T3 k-cap-same)
run_bench 50 4 "SELECT e_try_capture('cap', 'pay_e_same', '$O1');"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "applied once, 199 already_applied" "1,199" "$(q $DB "SELECT (SELECT count(*) FROM t_out WHERE tag='cap' AND outcome='applied') || ',' || (SELECT count(*) FROM t_out WHERE tag='cap' AND outcome='already_applied')")"
check "one payment activation, period extended once" "1,2026-11-01 10:00:00+05:30" "$(q $DB "SET timezone='Asia/Kolkata'; SELECT (SELECT count(*) FROM ent_activations WHERE tenant_id='$T3'::uuid AND kind='payment') || ',' || (SELECT current_period_end FROM ent_entitlements WHERE tenant_id='$T3'::uuid)" | tail -1)"
echo "-- 20 different captures for one tenant"
for i in $(seq 1 20); do q $DB "SELECT o_order_ref FROM pay_order_create('$T4'::uuid, 'eplat', 'k-multi-$i', 'subscription_period', '1', NULL, 58882, 'INR', 'razorpay', 'live', 'e-ord', e_spec(), 'bench')" >/dev/null; done
run_bench 20 1 "SELECT e_try_capture('multi', 'pay_e_multi_' || :client_id, (SELECT order_ref FROM pay_orders WHERE idempotency_key = 'k-multi-' || (:client_id + 1)));"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "20 applied" "20" "$(q $DB "SELECT count(*) FROM t_out WHERE tag='multi' AND outcome='applied'")"
check "stacked exactly 20 months: 1 Jun 2028" "20,2028-06-01 10:00:00+05:30" "$(q $DB "SET timezone='Asia/Kolkata'; SELECT (SELECT count(*) FROM ent_activations WHERE tenant_id='$T4'::uuid AND kind='payment') || ',' || (SELECT current_period_end FROM ent_entitlements WHERE tenant_id='$T4'::uuid)" | tail -1)"

drop_db $DB
finish "L7.4 entitlement concurrency"
