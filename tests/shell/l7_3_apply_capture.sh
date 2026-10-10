#!/usr/bin/env bash
# L7.3 acceptance that needs real concurrency (pgbench; see tests/shell/l7_1_numbering.sh for PGBENCH):
#   * the SAME capture delivered 200 times by 50 concurrent clients applies exactly once - invoice,
#     payment, entitlement extension, wallet grant, event, counter - for every purpose
#   * 20 concurrent DIFFERENT payments for one order: exactly one applies, the rest are refused
#   * 50 concurrent identical order-create requests produce exactly one order; 50 concurrent
#     gateway-order attaches have exactly one winner and everyone sees the same id
#   * 200 orders captured concurrently get invoice numbers exactly 1..200 (no gap, no duplicate)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${PGBENCH:-}" ]; then
  if command -v pgbench >/dev/null 2>&1; then PGBENCH="pgbench"; else
    echo "!! PGBENCH is not set and pgbench is not on PATH: the concurrency proofs cannot run." >&2; exit 1
  fi
fi

DB=paytest_l73
echo "== L7.3 apply_capture: concurrency"
new_db $DB
load_schema $DB || { fail "schema load"; finish "L7.3"; exit 1; }
activate_gateways $DB
widen_issue_window $DB

run_bench() { # run_bench <clients> <txns> <script>
  local out; out=$($PGBENCH -n -c "$1" -j 4 -t "$2" -f /dev/stdin $DB <<< "$3" 2>&1); BENCH_RC=$?
  BENCH_OUT="$out"
  echo "$out" | grep -E "number of transactions actually processed|number of failed transactions" | sed 's/^/    /'
}

q $DB "
SELECT _inv_issuer_upsert('c-issuer', 'cplat', NULL, 'Conc Pvt Ltd', 'regular', '29AAACX1234C1ZP', '29', 'Bengaluru', false, 'bench');
SELECT _inv_series_create('c-inv', 'c-issuer', 'invoice', 'live', 'CP', '/', 6, true, 'bench');
INSERT INTO pricing_plans (id, name, is_subscription, is_active, is_trial, created_at, created_by) VALUES
  (1, 'Monthly', true, true, false, '2026-01-01', 'seed'), (2, 'Licence', false, true, false, '2026-01-01', 'seed'), (3, 'Wallet', false, true, false, '2026-01-01', 'seed');
INSERT INTO subscription_pricing_plans (id, pricing_plan_id, duration, duration_uom, amount, is_amount_tax_exclusive, is_post_paid, is_active, created_at, created_by)
  VALUES (1, 1, 1, 'month', 49900, true, false, true, '2026-01-01', 'seed');
INSERT INTO one_time_pricing_plans (id, pricing_plan_id, duration, duration_uom, is_life_time, is_credit_system, credit_quantity, amount, is_amount_tax_exclusive, is_active, created_at, created_by)
  VALUES (1, 2, NULL, NULL, true, false, NULL, 199900, true, true, '2026-01-01', 'seed');
INSERT INTO wlt_packs (id, pricing_plan_id, name, credits_milli, created_by) VALUES (1, 3, 'Ten credits', 10000, 'seed');
CREATE TABLE t_out (tag TEXT, outcome TEXT);
CREATE TABLE t_ref (tag TEXT, val TEXT);

CREATE FUNCTION c_spec(p_price TEXT) RETURNS TEXT AS \$\$
    SELECT jsonb_build_object(
        'buyer', jsonb_build_object('legal_name', 'Buyer', 'registration_status', 'unregistered', 'address_state', 'Karnataka'),
        'billing_country_code', 'IN', 'billing_state', 'Karnataka', 'supply_type', 'domestic', 'price_is_inclusive', false,
        'round_off', false, 'due_days', 0,
        'lines', jsonb_build_array(jsonb_build_object('description', 'Item', 'hsn_sac', '998314', 'quantity', '1', 'unit_price', p_price, 'gst_rate', 0.18)))::text;
\$\$ LANGUAGE sql;

-- takes the next unpaid bulk order nobody else holds and captures it (SKIP LOCKED = a work queue)
CREATE FUNCTION c_take_next(p_tag TEXT) RETURNS VOID AS \$\$
DECLARE v_ref TEXT;
BEGIN
    SELECT order_ref INTO v_ref FROM pay_orders WHERE idempotency_key LIKE 'k-bulk-%' AND status IN ('created', 'open')
     ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED;
    IF v_ref IS NOT NULL THEN
        PERFORM c_try(p_tag, 'pay_bulk_' || v_ref, v_ref, 58882);
    END IF;
END; \$\$ LANGUAGE plpgsql;

-- a try-wrapper so a refusal is recorded instead of aborting the pgbench client
CREATE FUNCTION c_try(p_tag TEXT, p_txn TEXT, p_ref TEXT, p_amount BIGINT) RETURNS VOID AS \$\$
DECLARE v_out TEXT;
BEGIN
    BEGIN
        SELECT o_outcome INTO v_out FROM pay_apply_capture('razorpay', p_txn, p_ref, NULL, NULL, p_amount, 'INR', 'live', '2026-10-10 10:00+05:30', 'bench');
    EXCEPTION WHEN OTHERS THEN
        v_out := 'refused:' || SQLSTATE;
    END;
    INSERT INTO t_out VALUES (p_tag, v_out);
END; \$\$ LANGUAGE plpgsql;
" >/dev/null || { fail "fixtures"; finish "L7.3"; exit 1; }

mkorder() { # mkorder <tenant-suffix> <key> <purpose> <catalog> <amount> <price>
  q $DB "SELECT o_order_ref FROM pay_order_create('00000000-0000-0000-0000-0000000e$1'::uuid, 'cplat', '$2', '$3', '$4', NULL, $5, 'INR', 'razorpay', 'live', 'c-inv', c_spec('$6'), 'bench')"
}

# ---- 1. the same capture, 200 deliveries, per purpose ----
SUB=$(mkorder 0001 k-sub subscription_period 1 58882 499.00)
LIC=$(mkorder 0002 k-lic one_time_license 1 235882 1999.00)
WAL=$(mkorder 0003 k-wal wallet_topup 1 57820 490.00)
IPI=$(q $DB "SELECT inv_issue_invoice(NULL, '00000000-0000-0000-0000-0000000e0004'::uuid, 'cplat', 'postpaid', 'm1', '2026-09-01', '2026-09-30', '2026-10-30', 'IN', 'Karnataka', NULL,
   ROW('B', NULL, 'buyer', 'unregistered', 'Karnataka', NULL)::inv_party_input, 'domestic', NULL, false, false, 'INR', NULL, NULL, '2026-10-01',
   ARRAY[ROW('Usage','998314','1','100.00',0.18,NULL,false)::inv_line_input], NULL, 'bench', '2026-10-01', 'issued', 'c-inv', 'live')")
q $DB "SELECT inv_transition_invoice_status($IPI, '00000000-0000-0000-0000-0000000e0004'::uuid, 'cplat', 'due', 'bench', '2026-10-30')" >/dev/null
INV=$(q $DB "SELECT o_order_ref FROM pay_order_create('00000000-0000-0000-0000-0000000e0004'::uuid, 'cplat', 'k-inv', 'invoice_payment', NULL, $IPI, 11800, 'INR', 'razorpay', 'live', NULL, NULL, 'bench')")
for ref in "$SUB" "$LIC" "$WAL" "$INV"; do [ -n "$ref" ] || { fail "an order was not created"; finish "L7.3"; exit 1; }; done

CTR_BEFORE=$(q $DB "SELECT coalesce(sum(last_number),0) FROM inv_series_counter")
echo "-- 200 deliveries of one capture, 50 clients, per purpose"
for spec in "sub:$SUB:58882" "lic:$LIC:235882" "wal:$WAL:57820" "inv:$INV:11800"; do
  tag=${spec%%:*}; rest=${spec#*:}; ref=${rest%%:*}; amt=${rest#*:}
  run_bench 50 4 "SELECT c_try('$tag', 'pay_same_$tag', '$ref', $amt);"
  check "$tag: pgbench exited cleanly" "0" "$BENCH_RC"
  check "$tag: exactly one delivery applied it" "1" "$(q $DB "SELECT count(*) FROM t_out WHERE tag='$tag' AND outcome='applied'")"
  check "$tag: every other delivery was already_applied" "199" "$(q $DB "SELECT count(*) FROM t_out WHERE tag='$tag' AND outcome='already_applied'")"
  check "$tag: one captured-payment record" "1" "$(q $DB "SELECT count(*) FROM pay_captured_payments WHERE gateway_txn_ref='pay_same_$tag'")"
  check "$tag: one payment event" "1" "$(q $DB "SELECT count(*) FROM pay_events WHERE order_ref='$ref' AND event_type='payment.applied'")"
done
check "subscription: exactly one invoice" "1" "$(q $DB "SELECT count(*) FROM inv_invoices WHERE charge_ref='$SUB'")"
check "subscription: exactly one payment" "1" "$(q $DB "SELECT count(*) FROM inv_payments p JOIN inv_invoices i ON i.id=p.invoice_id WHERE i.charge_ref='$SUB'")"
check "subscription: exactly one entitlement extension" "1" "$(q $DB "SELECT count(*) FROM customer_pricing_plans WHERE tenant_id='00000000-0000-0000-0000-0000000e0001'::uuid")"
check "licence: exactly one invoice and one enrolment" "1,1" "$(q $DB "SELECT (SELECT count(*) FROM inv_invoices WHERE charge_ref='$LIC') || ',' || (SELECT count(*) FROM customer_pricing_plans WHERE tenant_id='00000000-0000-0000-0000-0000000e0002'::uuid)")"
check "wallet: exactly one invoice and one grant of 10 credits" "1,1,10" "$(q $DB "SELECT (SELECT count(*) FROM inv_invoices WHERE charge_ref='$WAL') || ',' || (SELECT count(*) FROM wlt_grants g JOIN wlt_wallets w ON w.id=g.wallet_id WHERE w.tenant_id='00000000-0000-0000-0000-0000000e0003'::uuid) || ',' || (SELECT coalesce(max(g.granted_milli),0)/1000 FROM wlt_grants g JOIN wlt_wallets w ON w.id=g.wallet_id WHERE w.tenant_id='00000000-0000-0000-0000-0000000e0003'::uuid)")"
check "invoice_payment: invoice paid once, no new invoice number" "paid,1" "$(q $DB "SELECT status || ',' || (SELECT count(*) FROM inv_payments WHERE invoice_id=$IPI) FROM inv_invoices WHERE id=$IPI")"
check "numbers: three new invoices took exactly three numbers" "3" "$(q $DB "SELECT coalesce(sum(last_number),0) - $CTR_BEFORE FROM inv_series_counter")"

# ---- 2. different payments racing for ONE order ----
RACE=$(mkorder 0005 k-race subscription_period 1 58882 499.00)
echo "-- 20 clients, each with a DIFFERENT payment id, for one order"
run_bench 20 1 "SELECT c_try('race', 'pay_race_' || :client_id, '$RACE', 58882);"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "exactly one payment applied" "1" "$(q $DB "SELECT count(*) FROM t_out WHERE tag='race' AND outcome='applied'")"
check "the other 19 went to the refund queue (money for an already-paid order)" "19" "$(q $DB "SELECT count(*) FROM t_out WHERE tag='race' AND outcome='refund_required'")"
check "and the queue holds exactly those 19, once each" "19" "$(q $DB "SELECT count(*) FROM pay_refund_queue WHERE order_ref='$RACE' AND status='open'")"
check "one invoice, one payment, one entitlement for the order" "1,1,1" "$(q $DB "SELECT (SELECT count(*) FROM inv_invoices WHERE charge_ref='$RACE') || ',' || (SELECT count(*) FROM pay_captured_payments WHERE reference='$RACE') || ',' || (SELECT count(*) FROM customer_pricing_plans WHERE tenant_id='00000000-0000-0000-0000-0000000e0005'::uuid)")"

# ---- 2b. the same unappliable payment redelivered concurrently queues once ----
CXL=$(mkorder 0007 k-cxl subscription_period 1 58882 499.00)
q $DB "UPDATE pay_orders SET status = 'cancelled' WHERE order_ref = '$CXL'" >/dev/null
echo "-- one payment for a CANCELLED order, delivered 200 times by 50 clients"
run_bench 50 4 "SELECT c_try('cxl', 'pay_cxl', '$CXL', 58882);"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "every delivery was told refund_required" "200" "$(q $DB "SELECT count(*) FROM t_out WHERE tag='cxl' AND outcome='refund_required'")"
check "exactly one refund-queue entry, nothing applied" "1,0" "$(q $DB "SELECT (SELECT count(*) FROM pay_refund_queue WHERE gateway_txn_ref='pay_cxl') || ',' || (SELECT count(*) FROM inv_invoices WHERE charge_ref='$CXL')")"

# ---- 2c. the gateway-create lease ----
LS=$(mkorder 0008 k-lease subscription_period 1 58882 499.00)
echo "-- 50 clients race for the gateway-create lease"
run_bench 50 1 "INSERT INTO t_ref SELECT 'lease', pay_order_begin_gateway_create('$LS')::text;"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "exactly one client got the lease" "1" "$(q $DB "SELECT count(*) FROM t_ref WHERE tag='lease' AND val='true'")"

# ---- 3. idempotent order creation under concurrency ----
echo "-- 200 identical order-create requests from 50 clients"
run_bench 50 4 "INSERT INTO t_ref SELECT 'create', o_order_ref FROM pay_order_create('00000000-0000-0000-0000-0000000e0006'::uuid, 'cplat', 'k-same', 'subscription_period', '1', NULL, 58882, 'INR', 'razorpay', 'live', 'c-inv', c_spec('499.00'), 'bench');"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "exactly one order exists" "1" "$(q $DB "SELECT count(*) FROM pay_orders WHERE idempotency_key='k-same'")"
check "every caller was handed the same order_ref" "1" "$(q $DB "SELECT count(DISTINCT val) FROM t_ref WHERE tag='create'")"
check "200 callers answered" "200" "$(q $DB "SELECT count(*) FROM t_ref WHERE tag='create'")"
ORD=$(q $DB "SELECT order_ref FROM pay_orders WHERE idempotency_key='k-same'")
echo "-- 50 racing gateway-order attaches"
run_bench 50 1 "WITH a AS (SELECT * FROM pay_order_attach_gateway_order('$ORD', 'gw_' || :client_id))
INSERT INTO t_ref SELECT 'attach', o_gateway_order_id FROM a UNION ALL SELECT 'winner', o_gateway_order_id FROM a WHERE o_attached;"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "exactly one attach won" "1" "$(q $DB "SELECT count(*) FROM t_ref WHERE tag='winner'")"
check "all 50 callers were given the winner's gateway order id" "1" "$(q $DB "SELECT count(DISTINCT val) FROM t_ref WHERE tag='attach'")"

# ---- 4. 200 different orders captured concurrently: gapless numbers ----
echo "-- 200 orders, captured concurrently by 40 clients"
q $DB "SELECT count(*) FROM generate_series(1, 200) g, LATERAL (SELECT o_order_ref FROM pay_order_create(('00000000-0000-0000-0000-000000f' || lpad(g::text, 5, '0'))::uuid, 'cplat', 'k-bulk-' || g, 'subscription_period', '1', NULL, 58882, 'INR', 'razorpay', 'live', 'c-inv', c_spec('499.00'), 'bench')) o" >/dev/null
BASE=$(q $DB "SELECT coalesce(sum(last_number),0) FROM inv_series_counter")
run_bench 40 5 "SELECT c_take_next('bulk');"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "all 200 captures applied" "200" "$(q $DB "SELECT count(*) FROM t_out WHERE tag='bulk' AND outcome='applied'")"
check "200 paid invoices, one per order" "200" "$(q $DB "SELECT count(*) FROM inv_invoices WHERE charge_source='subscription_period' AND charge_ref IN (SELECT order_ref FROM pay_orders WHERE idempotency_key LIKE 'k-bulk-%') AND status='paid'")"
check "their numbers are exactly the next 200 serials (no gap, no duplicate)" "0" \
  "$(q $DB "SELECT count(*) FROM ((SELECT g FROM generate_series($BASE + 1, $BASE + 200) g EXCEPT SELECT number_seq FROM inv_invoices WHERE charge_ref IN (SELECT order_ref FROM pay_orders WHERE idempotency_key LIKE 'k-bulk-%'))
                               UNION ALL (SELECT number_seq FROM inv_invoices WHERE charge_ref IN (SELECT order_ref FROM pay_orders WHERE idempotency_key LIKE 'k-bulk-%') EXCEPT SELECT g FROM generate_series($BASE + 1, $BASE + 200) g)) d")"

drop_db $DB
finish "L7.3 apply_capture concurrency"
