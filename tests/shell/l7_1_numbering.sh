#!/usr/bin/env bash
# L7.1 acceptance, the parts a single SQL session cannot prove:
#   * 1000 concurrent issuances on one series yield exactly 1..1000, no gap, no duplicate
#   * a mix of committed and rolled-back concurrent issuances stays gapless (rollback never burns)
#   * concurrent draft -> issued edges allocate 1..N exactly once each
#   * two series issued concurrently keep independent gapless counters
#   * _pay_apply_schema_upgrades() turns a database holding the previous release's
#     invoice table into exactly the shape a fresh database has, keeping its rows
#
# Needs pgbench on a server the PSQL variable can reach. PGBENCH is the complete pgbench
# command prefix including host/user, e.g.
#   PGBENCH='pgbench -h 127.0.0.1 -p 55432 -U postgres'
#   PGBENCH='docker exec -i some-postgres-container pgbench -h 127.0.0.1 -U postgres'
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${PGBENCH:-}" ]; then
  if command -v pgbench >/dev/null 2>&1; then
    PGBENCH="pgbench"
  else
    echo "!! PGBENCH is not set and pgbench is not on PATH: the concurrency proofs cannot run." >&2
    echo "!! Set PGBENCH (see the header of this file). Skipping is never silent: failing." >&2
    exit 1
  fi
fi

DB=paytest_l71_conc
echo "== L7.1 concurrency + upgrade"
new_db $DB
load_schema $DB || { fail "schema load"; finish "L7.1"; exit 1; }
widen_issue_window $DB

q $DB "SELECT _inv_issuer_upsert('conc-issuer','l71conc',NULL,'Conc Pvt Ltd','regular','29AAACX1234C1ZP','29','Bengaluru',false,'bench')" >/dev/null
for spec in "conc-inv:CC:5" "mix-inv:MX:5" "draft-conc:DC:5" "par-1:PA:5" "par-2:PB:5" "fy-inv:FY:5" "adopt-inv:AD:5" "dbl-inv:DB:5"; do
  code=${spec%%:*}; rest=${spec#*:}; pre=${rest%%:*}; w=${rest#*:}
  q $DB "SELECT _inv_series_create('$code','conc-issuer','invoice','live','$pre','/',$w,true,'bench')" >/dev/null
done

q $DB "
CREATE FUNCTION l71_issue(p_series TEXT, p_status TEXT DEFAULT 'issued', p_at TIMESTAMPTZ DEFAULT '2026-10-10 10:00+05:30') RETURNS BIGINT AS \$\$
    SELECT inv_issue_invoice(NULL, '00000000-0000-0000-0000-0000000c0001', 'l71conc', 'bench', NULL,
        p_at, p_at, '2026-11-10',
        'IN', 'Karnataka', NULL,
        ROW('Buyer', NULL, 'buyer', 'unregistered', 'Karnataka', NULL)::inv_party_input,
        'domestic', NULL, false, false, 'INR', NULL, NULL, p_at,
        ARRAY[ROW('Service','998314','1','100.00',0.18,NULL,false)::inv_line_input],
        NULL, 'bench', p_at, p_status, p_series, 'live');
\$\$ LANGUAGE sql;
-- a wrapper that records an error instead of aborting the pgbench client
CREATE TABLE t_out (tag TEXT, outcome TEXT);
CREATE FUNCTION l71_try_edge(p_id BIGINT) RETURNS VOID AS \$\$
DECLARE v TEXT;
BEGIN
    BEGIN
        v := inv_transition_invoice_status(p_id, '00000000-0000-0000-0000-0000000c0001', 'l71conc', 'issued', 'bench', '2026-10-10 10:00+05:30');
    EXCEPTION WHEN OTHERS THEN
        v := 'refused:' || SQLSTATE;
    END;
    INSERT INTO t_out VALUES ('edge', v);
END; \$\$ LANGUAGE plpgsql;" >/dev/null

# run_bench <clients> <txns-per-client> <script> -> prints a one-line summary, sets BENCH_RC
run_bench() {
  local out
  out=$($PGBENCH -n -c "$1" -j 4 -t "$2" -f /dev/stdin $DB <<< "$3" 2>&1); BENCH_RC=$?
  echo "$out" | grep -E "number of transactions actually processed|number of failed transactions|latency average|tps" | sed 's/^/    /'
  BENCH_OUT="$out"
}

# serials_ok <series_code> <expected_count> <label>
serials_ok() {
  local s="$1" n="$2" label="$3" got gaps
  got=$(q $DB "SELECT count(*) || ',' || count(DISTINCT invoice_number) || ',' || coalesce(min(number_seq),0) || ',' || coalesce(max(number_seq),0)
               FROM inv_invoices WHERE series_id = (SELECT id FROM inv_series WHERE series_code = '$s') AND invoice_number IS NOT NULL")
  check "$label: count, distinct numbers, min and max serial" "$n,$n,1,$n" "$got"
  gaps=$(q $DB "SELECT count(*) FROM (
                  (SELECT g FROM generate_series(1, $n) g EXCEPT SELECT number_seq FROM inv_invoices WHERE series_id = (SELECT id FROM inv_series WHERE series_code = '$s'))
                  UNION ALL
                  (SELECT number_seq FROM inv_invoices WHERE series_id = (SELECT id FROM inv_series WHERE series_code = '$s') EXCEPT SELECT g FROM generate_series(1, $n) g)) d")
  check "$label: serial set is exactly 1..$n (no gap, no duplicate)" "0" "$gaps"
  check "$label: counter equals the number of issued invoices" "$n" \
    "$(q $DB "SELECT coalesce(max(c.last_number),0) FROM inv_series_counter c JOIN inv_series s ON s.id = c.series_id WHERE s.series_code = '$s'")"
  check "$label: every stored number is the formatted serial" "0" \
    "$(q $DB "SELECT count(*) FROM inv_invoices i JOIN inv_series s ON s.id = i.series_id WHERE s.series_code = '$s' AND i.invoice_number IS NOT NULL AND i.invoice_number <> s.prefix || s.sep || i.fy_label || s.sep || lpad(i.number_seq::text, s.width, '0')")"
}

# ---- 1. 1000 concurrent issuances, one series ----
echo "-- 1000 issuances, 50 concurrent clients, one series"
run_bench 50 20 "SELECT l71_issue('conc-inv');"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "pgbench reports no failed transaction" "0" "$(echo "$BENCH_OUT" | sed -n 's/^number of failed transactions: \([0-9]*\).*/\1/p' | head -1)"
serials_ok conc-inv 1000 "1000 concurrent issuances"

# ---- 2. commit / rollback mix ----
echo "-- 1000 attempts, ~30% rolled back, 40 concurrent clients"
run_bench 40 25 "\\set r random(1, 100)
BEGIN;
SELECT l71_issue('mix-inv');
\\if :r <= 30
ROLLBACK;
\\else
COMMIT;
\\endif"
check "pgbench exited cleanly" "0" "$BENCH_RC"
COMMITTED=$(q $DB "SELECT count(*) FROM inv_invoices WHERE series_id = (SELECT id FROM inv_series WHERE series_code='mix-inv')")
echo "    committed: $COMMITTED of 1000 attempts"
check "some attempts really were rolled back (the mix is real)" "t" "$(q $DB "SELECT $COMMITTED BETWEEN 500 AND 900")"
serials_ok mix-inv "$COMMITTED" "commit/rollback mix"

# ---- 3. concurrent draft -> issued edges ----
echo "-- 300 drafts, issued by 30 concurrent clients"
q $DB "SELECT count(l71_issue('draft-conc', 'draft')) FROM generate_series(1, 300)" >/dev/null
check "drafts hold no number and consumed none" "0,0" \
  "$(q $DB "SELECT count(*) FILTER (WHERE invoice_number IS NOT NULL) || ',' || coalesce((SELECT max(c.last_number) FROM inv_series_counter c JOIN inv_series s ON s.id=c.series_id WHERE s.series_code='draft-conc'),0) FROM inv_invoices WHERE status='draft'")"
run_bench 30 10 "BEGIN;
SELECT id AS did FROM inv_invoices WHERE status = 'draft' AND series_id = (SELECT id FROM inv_series WHERE series_code = 'draft-conc') ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED \\gset
SELECT inv_transition_invoice_status(:did, '00000000-0000-0000-0000-0000000c0001', 'l71conc', 'issued', 'bench', '2026-10-10 10:00+05:30');
COMMIT;"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "every draft was issued" "300" "$(q $DB "SELECT count(*) FROM inv_invoices WHERE status='issued' AND series_id=(SELECT id FROM inv_series WHERE series_code='draft-conc')")"
serials_ok draft-conc 300 "concurrent draft -> issued edges"

# ---- 4. two series at once ----
echo "-- 1000 issuances spread at random over two series"
run_bench 40 25 "\\set s random(1, 2)
SELECT l71_issue('par-' || :s::text);"
check "pgbench exited cleanly" "0" "$BENCH_RC"
N1=$(q $DB "SELECT count(*) FROM inv_invoices WHERE series_id=(SELECT id FROM inv_series WHERE series_code='par-1')")
N2=$(q $DB "SELECT count(*) FROM inv_invoices WHERE series_id=(SELECT id FROM inv_series WHERE series_code='par-2')")
check "all 1000 issuances landed" "1000" "$((N1 + N2))"
serials_ok par-1 "$N1" "series par-1"
serials_ok par-2 "$N2" "series par-2"

# ---- 4b. financial-year boundary: documents dated either side of 1 April, issued concurrently ----
echo "-- 1000 issuances dated 31-Mar 23:00 or 01-Apr 01:00 IST, 40 concurrent clients"
run_bench 40 25 "\\set r random(0, 1)
SELECT l71_issue('fy-inv', 'issued', CASE WHEN :r = 0 THEN '2027-03-31 23:00+05:30' ELSE '2027-04-01 01:00+05:30' END::timestamptz);"
check "pgbench exited cleanly" "0" "$BENCH_RC"
FYA=$(q $DB "SELECT count(*) FROM inv_invoices WHERE fy_label='26-27' AND series_id=(SELECT id FROM inv_series WHERE series_code='fy-inv')")
FYB=$(q $DB "SELECT count(*) FROM inv_invoices WHERE fy_label='27-28' AND series_id=(SELECT id FROM inv_series WHERE series_code='fy-inv')")
check "both financial years were used and add up to 1000" "1000" "$((FYA + FYB))"
check "FY 26-27 serials are exactly 1..$FYA" "0" "$(q $DB "SELECT count(*) FROM ((SELECT g FROM generate_series(1,$FYA) g EXCEPT SELECT number_seq FROM inv_invoices WHERE fy_label='26-27' AND series_id=(SELECT id FROM inv_series WHERE series_code='fy-inv')) UNION ALL (SELECT number_seq FROM inv_invoices WHERE fy_label='26-27' AND series_id=(SELECT id FROM inv_series WHERE series_code='fy-inv') EXCEPT SELECT g FROM generate_series(1,$FYA) g)) d")"
check "FY 27-28 serials are exactly 1..$FYB" "0" "$(q $DB "SELECT count(*) FROM ((SELECT g FROM generate_series(1,$FYB) g EXCEPT SELECT number_seq FROM inv_invoices WHERE fy_label='27-28' AND series_id=(SELECT id FROM inv_series WHERE series_code='fy-inv')) UNION ALL (SELECT number_seq FROM inv_invoices WHERE fy_label='27-28' AND series_id=(SELECT id FROM inv_series WHERE series_code='fy-inv') EXCEPT SELECT g FROM generate_series(1,$FYB) g)) d")"
check "no document dated before 1 April carries an FY 27-28 number (nothing out of order)" "0" "$(q $DB "SELECT count(*) FROM inv_invoices WHERE series_id=(SELECT id FROM inv_series WHERE series_code='fy-inv') AND ((issue_date < '2027-04-01' AND fy_label<>'26-27') OR (issue_date >= '2027-04-01' AND fy_label<>'27-28'))")"
check "gap audit finds nothing" "0" "$(q $DB "SELECT count(*) FROM inv_series_gap_audit('fy-inv')")"

# ---- 4c. adopt racing issuance ----
echo "-- 300 issuances while another session adopts the counter forward to 5000"
( $PGBENCH -n -c 20 -j 4 -t 15 -f /dev/stdin $DB > /dev/null 2>&1 <<< "SELECT l71_issue('adopt-inv', 'issued', now());" ) &
BGPID=$!
sleep 1
q $DB "SELECT o_applied FROM _inv_series_adopt('adopt-inv', _inv_in_fy_label(now()), 5000, 'concurrent adoption test', 'bench')" >/dev/null 2>&1
wait $BGPID
check "all 300 issuances succeeded" "300" "$(q $DB "SELECT count(*) FROM inv_invoices WHERE series_id=(SELECT id FROM inv_series WHERE series_code='adopt-inv')")"
check "no duplicate serial" "300" "$(q $DB "SELECT count(DISTINCT number_seq) FROM inv_invoices WHERE series_id=(SELECT id FROM inv_series WHERE series_code='adopt-inv')")"
ADOPTED=$(q $DB "SELECT count(*) FROM inv_series_adoptions a JOIN inv_series s ON s.id=a.series_id WHERE s.series_code='adopt-inv'")
check "the adoption was recorded exactly once" "1" "$ADOPTED"
LOW=$(q $DB "SELECT count(*) FROM inv_invoices WHERE number_seq <= 300 AND series_id=(SELECT id FROM inv_series WHERE series_code='adopt-inv')")
check "serials before the adoption are exactly 1..n and after it start at 5001, nothing in between" "t" \
  "$(q $DB "SELECT (SELECT count(*) = $LOW AND coalesce(max(number_seq),0) = $LOW FROM inv_invoices WHERE number_seq <= 5000 AND series_id=(SELECT id FROM inv_series WHERE series_code='adopt-inv'))
        AND (SELECT coalesce(min(number_seq),5001) = 5001 AND coalesce(max(number_seq),5000) = 5000 + (300 - $LOW) FROM inv_invoices WHERE number_seq > 5000 AND series_id=(SELECT id FROM inv_series WHERE series_code='adopt-inv'))")"
check "gap audit finds nothing (the adopted range is expected to live elsewhere)" "0" "$(q $DB "SELECT count(*) FROM inv_series_gap_audit('adopt-inv')")"

# ---- 4d. one draft issued by many sessions at once, no SKIP LOCKED ----
echo "-- one draft, 30 concurrent clients each trying to issue it"
DRAFT=$(q $DB "SELECT l71_issue('dbl-inv', 'draft')")
run_bench 30 1 "SELECT l71_try_edge($DRAFT);"
check "pgbench exited cleanly" "0" "$BENCH_RC"
check "exactly one session issued it" "1" "$(q $DB "SELECT count(*) FROM t_out WHERE tag='edge' AND outcome='issued'")"
check "the other 29 were refused" "29" "$(q $DB "SELECT count(*) FROM t_out WHERE tag='edge' AND outcome LIKE 'refused:%'")"
check "it carries serial 1 and the counter is 1" "1,1" "$(q $DB "SELECT number_seq || ',' || (SELECT last_number FROM inv_series_counter c JOIN inv_series s ON s.id=c.series_id WHERE s.series_code='dbl-inv') FROM inv_invoices WHERE id=$DRAFT")"

drop_db $DB

# ---- 5. upgrading the previous release's invoice table in place ----
echo "-- _pay_apply_schema_upgrades() on a database holding the previous release's shape"
new_db paytest_up_fresh
load_schema paytest_up_fresh || fail "fresh schema load"
new_db paytest_up_old
load_schema paytest_up_old || fail "old schema load"
# put inv_invoices back into the previous release's shape (a throwaway DB: dropping here is the test fixture)
q paytest_up_old "
ALTER TABLE inv_invoices DISABLE TRIGGER inv_invoices_guard;
DROP INDEX inv_invoices_series_serial;
DROP INDEX inv_invoices_issuer;
ALTER TABLE inv_invoices
    DROP COLUMN issuer_id, DROP COLUMN series_id, DROP COLUMN fy_label, DROP COLUMN number_seq, DROP COLUMN mode,
    DROP COLUMN issue_date, DROP COLUMN seller_legal_name, DROP COLUMN seller_gstin, DROP COLUMN seller_registration_status,
    DROP COLUMN seller_state_code, DROP COLUMN seller_address, DROP COLUMN buyer_legal_name, DROP COLUMN buyer_gstin,
    DROP COLUMN buyer_registration_status, DROP COLUMN buyer_state_code;
ALTER TABLE inv_invoices ALTER COLUMN invoice_number SET NOT NULL;
INSERT INTO inv_invoices (invoice_number, tenant_id, platform_code, charge_source, document_type, tax_treatment,
    taxable_value_minor, gross_total_minor, currency, billing_country_code, status, created_by, issued_at)
VALUES ('PRE-000001', '00000000-0000-0000-0000-0000000d0001', 'l71up', 'x', 'tax_invoice', 'intrastate', 10000, 11800, 'INR', 'IN', 'issued', 'legacy', '2026-01-01'),
       ('PRE-000002', '00000000-0000-0000-0000-0000000d0001', 'l71up', 'x', 'tax_invoice', 'intrastate', 20000, 23600, 'INR', 'IN', 'draft', 'legacy', NULL),
       ('TEST-000009', '00000000-0000-0000-0000-0000000d0001', 'l71up', 'x', 'tax_invoice', 'intrastate', 30000, 35400, 'INR', 'IN', 'issued', 'legacy', '2026-01-02');
ALTER TABLE inv_invoices ENABLE TRIGGER inv_invoices_guard;" >/dev/null || fail "build the previous-release shape"
shape() {
  q "$1" "SELECT 'cols=' || coalesce((SELECT string_agg(column_name || ':' || data_type || ':' || is_nullable || ':' || coalesce(column_default,''), ',' ORDER BY column_name)
                 FROM information_schema.columns WHERE table_name='inv_invoices'),'')
          || ' idx=' || coalesce((SELECT string_agg(indexname || '=' || indexdef, ';' ORDER BY indexname) FROM pg_indexes WHERE tablename='inv_invoices'),'')
          || ' con=' || coalesce((SELECT string_agg(conname || '=' || pg_get_constraintdef(oid), ';' ORDER BY conname) FROM pg_constraint WHERE conrelid='inv_invoices'::regclass),'')"
}
check "the old-shape fixture really differs from a fresh database" "t" "$([ "$(shape paytest_up_old)" != "$(shape paytest_up_fresh)" ] && echo t || echo f)"
CHANGES=$(q paytest_up_old "SELECT count(*) FROM _pay_apply_schema_upgrades()")
check "upgrade reports its changes (15 columns, nullable number, 2 indexes, mode back-fill)" "19" "$CHANGES"
check "upgraded shape (columns, defaults, nullability, indexes, constraints) equals a fresh database" "$(shape paytest_up_fresh)" "$(shape paytest_up_old)"
check "second run changes nothing" "0" "$(q paytest_up_old 'SELECT count(*) FROM _pay_apply_schema_upgrades()')"
check "fresh database: upgrade is a no-op" "0" "$(q paytest_up_fresh 'SELECT count(*) FROM _pay_apply_schema_upgrades()')"
check "pre-existing invoices untouched" "PRE-000001,PRE-000002,TEST-000009,11800,23600,35400" \
  "$(q paytest_up_old "SELECT string_agg(invoice_number, ',' ORDER BY invoice_number) || ',' || string_agg(gross_total_minor::text, ',' ORDER BY invoice_number) FROM inv_invoices")"
check "pre-existing invoices have no series (they are recognisable)" "3" "$(q paytest_up_old 'SELECT count(*) FROM inv_invoices WHERE series_id IS NULL AND issuer_id IS NULL')"
check "legacy modes back-filled: PRE rows live, the TEST-numbered row test" "live,live,test" "$(q paytest_up_old "SELECT string_agg(mode, ',' ORDER BY invoice_number) FROM inv_invoices")"
activate_gateways paytest_up_old; widen_issue_window paytest_up_old
q paytest_up_old "SELECT inv_transition_invoice_status(id, tenant_id, platform_code, 'due', 't', now()) FROM inv_invoices WHERE invoice_number='PRE-000001' AND status <> 'due'" >/dev/null
ORDER_PROBE="DO \$\$ DECLARE i inv_invoices; BEGIN SELECT * INTO i FROM inv_invoices WHERE invoice_number='PRE-000001';
  PERFORM * FROM pay_order_create(i.tenant_id, i.platform_code, 'legacy-probe-%s', 'invoice_payment', NULL, i.id, i.gross_total_minor, 'INR', 'razorpay', '%s', NULL, NULL, 't');
  RAISE WARNING 'ORDER-CREATED'; END \$\$"
TEST_TRY=$($PSQL -d paytest_up_old -v ON_ERROR_STOP=1 -c "$(printf "$ORDER_PROBE" t test)" 2>&1)
LIVE_TRY=$($PSQL -d paytest_up_old -v ON_ERROR_STOP=1 -c "$(printf "$ORDER_PROBE" l live)" 2>&1)
check "a test-mode order can never settle a legacy live invoice (pay_order_create refuses it)" "t" "$(echo "$TEST_TRY" | grep -q 'cannot be paid through a test order' && echo t || echo f)"
check "while a live-mode order for that legacy invoice is accepted" "t" "$(echo "$LIVE_TRY" | grep -q 'ORDER-CREATED' && echo t || echo f)"
# and the upgraded database issues from a series, adopting over its existing numbers
q paytest_up_old "SELECT _inv_issuer_upsert('up-issuer','l71up',NULL,'Up Pvt Ltd','regular','29AAACX1234C1ZP','29','x',false,'t')" >/dev/null
q paytest_up_old "SELECT _inv_series_create('pre-series','up-issuer','invoice','live','PRE','-',6,false,'t')" >/dev/null
check "adopting the legacy series continues at last+1" "PRE-000003" "$(q paytest_up_old "
  SELECT o_new_last FROM _inv_series_adopt('pre-series', NULL, 2, 'previous release rows', 't');
  SELECT set_config('pay.issuing', 'on', true);
  SELECT (SELECT o_invoice_number FROM _inv_series_allocate('pre-series', now(), 'live'))" | tail -1)"
drop_db paytest_up_fresh; drop_db paytest_up_old

finish "L7.1 concurrency + upgrade"
