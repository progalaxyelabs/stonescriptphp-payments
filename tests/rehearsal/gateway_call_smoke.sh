#!/usr/bin/env bash
# Drives the library's SQL entry points through a REAL gateway's /call endpoint, with the argument
# shapes the PHP module sends (JSON text for json, ISO strings for timestamps, text uuids, NULLs,
# booleans, bigints), and checks the rows that come back. Proves the transport contract, not just
# the SQL: run it against every gateway line the library is deployed behind.
#
#   GATEWAY_URL=http://127.0.0.1:19000 ADMIN_TOKEN=... WORK=/empty/scratch/dir \
#   PSQL='psql ...' bash tests/rehearsal/gateway_call_smoke.sh
#
# NEVER point it at a shared or production gateway (it creates a platform and database).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../shell/lib.sh"
: "${GATEWAY_URL:?}" "${ADMIN_TOKEN:?}" "${WORK:?}"
mkdir -p "$WORK"
P="smk$(date +%s)"
echo "== gateway /call smoke ($(curl -s "$GATEWAY_URL/health" | jq -r .version)) platform=$P"

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

# call <function> <params-json-array> -> rows json in $WORK/call.json, http in $CALL_HTTP
call() {
  CALL_HTTP=$(curl -s -o "$WORK/call.json" -w '%{http_code}' -X POST "$GATEWAY_URL/call" -H 'Content-Type: application/json' \
    -d "{\"platform\":\"$P\",\"schema_name\":\"main\",\"function\":\"$1\",\"params\":$2}")
}
field() { jq -r ".rows[0].$1" "$WORK/call.json"; }
ok() { # ok <description> <expected> <jq field>
  check "$1" "$2" "$(field "$3")"
}

T=00000000-0000-0000-0000-0000000a0a01

call pay_webhook_record '["razorpay","evt_smoke_1","payment.captured","'$P'","{\"event\":\"payment.captured\"}","{\"content-type\":\"application/json\",\"authorization\":\"x\"}","{\"type\":\"payment.captured\"}","received",null]'
check "pay_webhook_record (JSON as text, NULL error)" 200 "$CALL_HTTP"
ok "  it is new" "true" o_is_new
INBOX_ID=$(field o_id)
call pay_webhook_record '["razorpay","evt_smoke_1","payment.captured","'$P'","{}","{}",null,"received",null]'
ok "  a redelivery is not new" "false" o_is_new
call pay_webhook_claim "[$INBOX_ID,120]"
check "pay_webhook_claim takes the lease (one row back)" 1 "$(jq '.rows | length' "$WORK/call.json")"
call pay_webhook_mark "[$INBOX_ID,\"applied\",null,null]"
ok "pay_webhook_mark records the outcome" "applied" o_status
call pay_webhook_claim "[$INBOX_ID,120]"
check "  an applied row can no longer be claimed (no rows)" 0 "$(jq '.rows | length' "$WORK/call.json")"

# an order and its capture-first settlement, through the transport
SPEC='{"buyer":{"legal_name":"Buyer","registration_status":"unregistered","address_state":"Karnataka"},"billing_country_code":"IN","billing_state":"Karnataka","supply_type":"domestic","price_is_inclusive":false,"round_off":false,"due_days":0,"lines":[{"description":"Item","hsn_sac":"998314","quantity":"1","unit_price":"499.00","gst_rate":0.18}]}'
SPEC_ESC=$(printf '%s' "$SPEC" | jq -Rs .)
DB="${P}_main"
# setup acts (issuer, series) are INTERNAL functions: a deployment runs them from a migration or an operator session, never over /call
$PSQL -d "$DB" -qc "SELECT _inv_issuer_upsert('smoke-issuer','$P',NULL,'Smoke Pvt Ltd','regular','29AAACX1234C1ZP','29','Bengaluru',false,'smoke'); SELECT _inv_series_create('smoke-inv','smoke-issuer','invoice','live','SM','/',5,true,'smoke');" >/dev/null
$PSQL -d "$DB" -qc "UPDATE inv_gateways SET is_active = true; UPDATE inv_gst_config SET config_value = '36500' WHERE config_key IN ('issue_date_window_days_live', 'issue_date_window_days_test');" >/dev/null
$PSQL -d "$DB" -qc "INSERT INTO pricing_plans (id, name, is_subscription, is_active, is_trial, created_at, created_by) VALUES (7001, 'Monthly', true, true, false, '2026-01-01', 'seed'); INSERT INTO subscription_pricing_plans (id, pricing_plan_id, duration, duration_uom, amount, is_amount_tax_exclusive, is_post_paid, is_active, created_at, created_by) VALUES (7001, 7001, 1, 'month', 49900, true, false, true, '2026-01-01', 'seed');" >/dev/null
call pay_order_quote '["'$T'","'$P'","smoke-inv",'"$SPEC_ESC"',"INR"]'
check "pay_order_quote (uuid text, JSON text) answers the total pay_order_create will enforce" "58882" "$(field o_gross_minor)"
call pay_order_create '["'$T'","'$P'","smoke-key-1","subscription_period","7001",null,58882,"INR","razorpay","live","smoke-inv",'"$SPEC_ESC"',"smoke"]'
check "pay_order_create (uuid text, NULL bigint, JSON text)" 200 "$CALL_HTTP"
REF=$(field o_order_ref)
ok "  new order" "true" o_is_new
call pay_order_create '["'$T'","'$P'","smoke-key-1","subscription_period","7001",null,58882,"INR","razorpay","live","smoke-inv",'"$SPEC_ESC"',"smoke"]'
check "  the retry returns the same order" "$REF" "$(field o_order_ref)"
call pay_order_attach_gateway_order '["'$REF'","order_smoke_1"]'
ok "  attach" "true" o_attached
call pay_apply_capture '["razorpay","pay_smoke_1","'$REF'","'$T'","'$P'",58882,"INR","live","2026-10-10T10:00:00+05:30","smoke","{\"id\":\"pay_smoke_1\"}"]'
check "pay_apply_capture (ISO timestamp, bigint, JSON text)" 200 "$CALL_HTTP"
ok "  applied" "applied" o_outcome
call pay_apply_capture '["razorpay","pay_smoke_1","'$REF'","'$T'","'$P'",58882,"INR","live","2026-10-10T10:00:00+05:30","smoke",null,"2026-10-10T10:00:00+05:30"]'
ok "  redelivery is already_applied" "already_applied" o_outcome
call pay_apply_capture '["razorpay","pay_smoke_2","ord_nope",null,null,58882,"INR","live","2026-10-10T10:00:00+05:30","smoke",null]'
ok "  unknown order is unattributed" "unattributed" o_outcome
call pay_apply_capture '["razorpay","pay_smoke_3","'$REF'","'$T'","'$P'",1,"INR","live","2026-10-10T10:00:00+05:30","smoke",null]'
check "  a mismatching capture is queued for refund and answered 200 (never raised away)" "refund_required,200" "$(field o_outcome),$CALL_HTTP"
call pay_refund_queue_aged '[100]'
check "pay_refund_queue_aged (fresh entry is not yet aged)" 0 "$(jq '.rows | length' "$WORK/call.json")"
check "the mismatching transaction is in the refund queue" "review_mismatch" "$($PSQL -d "$DB" -tAc "SELECT reason FROM pay_refund_queue WHERE gateway_txn_ref = 'pay_smoke_3'")"
check "the invoice exists, numbered (first serial of its FY) and paid" "true,paid" "$($PSQL -d "$DB" -tAc "SELECT (invoice_number ~ '^SM/[0-9]{2}-[0-9]{2}/00001\$') || ',' || status FROM inv_invoices WHERE charge_ref = '$REF'")"
call ent_get '["'$T'","'$P'","default"]'
ok "ent_get after the capture (uuid text, defaulted product): active, a period end" "active" o_status
# admin and scheduler actions are INTERNAL: run them the way an operator does (direct connection), never over /call
$PSQL -d "$DB" -qc "SELECT * FROM _ent_comp_activate('$T'::uuid, '$P', 'default', 'comp-pro', 30, 'smoke-comp-1', 'admin:smoke', 'smoke')" >/dev/null
check "_ent_comp_activate over a direct connection extended the entitlement" "1" "$($PSQL -d "$DB" -tAc "SELECT count(*) FROM ent_activations WHERE tenant_id = '$T'::uuid AND idempotency_key = 'smoke-comp-1'")"
call ent_get '["'$T'","'$P'","default"]'
ok "ent_get after a comp and a capture: active" "active" o_status
GWMINOR=$(curl -s "$GATEWAY_URL/health" | jq -r .version | awk -F. '{print $1*1000+$2}')
call _ent_tick '["2026-10-10T10:00:00+05:30",10,0]'
if [ "$GWMINOR" -ge 4008 ]; then
  check "an internal function over /call is REFUSED by this gateway (4.8+)" "t" "$([ "$CALL_HTTP" != 200 ] && echo t || echo f)"
fi
# wallet: minting credit is INTERNAL (operator, direct connection); spending and reading are public over /call
$PSQL -d "$DB" -qc "SELECT * FROM _wlt_grant_free('$T'::uuid, '$P', 'smoke-free-1', 5000, '2026-01-01', NULL, 'admin:smoke', 'smoke')" >/dev/null
call wallet_drain '["'$T'","'$P'","smoke-tick-1",1250,"2026-10-10T10:01:00+05:30","smoke","meter"]'
ok "wallet_drain applies (bigint milli-credits, timestamptz)" "applied" o_outcome
call wallet_drain '["'$T'","'$P'","smoke-tick-1",1250,"2026-10-10T10:01:00+05:30","smoke","meter"]'
ok "  a repeated tick is already_applied" "already_applied" o_outcome
call wallet_drain '["'$T'","'$P'","smoke-tick-2",999999,"2026-10-10T10:02:00+05:30","smoke","meter"]'
ok "  the hard stop answers insufficient with 200" "insufficient" o_outcome
call wallet_drain_cumulative '["'$T'","'$P'","vm-1","t1","12.5",17,60,"2026-10-10T10:03:00+05:30","smoke","meter"]'
ok "wallet_drain_cumulative (numeric as text, bigint rate): floor(12.5 x 17/60) = 3" "3" o_debited_milli
call wallet_balance '["'$T'","'$P'","2026-10-10T10:04:00+05:30"]'
ok "wallet_balance" "3747" o_milli
check "the books balance (_ledger_verify is internal: run directly)" "0" "$($PSQL -d "$DB" -tAc "SELECT count(*) FROM _ledger_verify()")"
call pay_order_get '["'$REF'","'$T'","'$P'"]'
ok "pay_order_get reads the paid order" "paid" o_status

finish "gateway /call smoke"
