#!/usr/bin/env bash
# L7.0 acceptance: _pay_ensure_reference_data() is idempotent and converges a
# fresh database, a database that predates the package, and a partially
# seeded database to the SAME reference rows.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TABLES="inv_gateways inv_gateway_routing_rules inv_invoice_statuses inv_invoice_status_transitions \
inv_outbox_directions inv_outbox_statuses inv_outbox_intimation_statuses inv_outbox_config \
inv_gst_state_codes inv_gst_state_name_aliases inv_gst_config inv_gst_rate_slabs \
inv_fx_reference_rates inv_tax_scheme pay_config"
# children first, for wiping
TABLES_REV="pay_config inv_tax_scheme inv_fx_reference_rates inv_gst_rate_slabs inv_gst_config inv_gst_state_name_aliases \
inv_gst_state_codes inv_outbox_config inv_outbox_intimation_statuses inv_outbox_statuses inv_outbox_directions \
inv_invoice_status_transitions inv_invoice_statuses inv_gateway_routing_rules inv_gateways"

# One stable fingerprint line per table: "<table> <count> <md5 of all rows, id columns excluded>".
fingerprint() {
  local db="$1" t out=""
  for t in $TABLES; do
    local cols
    # id is a surrogate; inv_tax_scheme.created_at defaults to now() because its seeder omits it
    cols=$(q "$db" "SELECT string_agg(quote_ident(column_name), ',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_name='$t' AND column_name <> 'id' AND NOT ('$t' = 'inv_tax_scheme' AND column_name = 'created_at')")
    out+="$t $(q "$db" "SELECT count(*) || ' ' || coalesce(md5(string_agg(r::text, '|' ORDER BY r::text)),'-') FROM (SELECT $cols FROM $t) r")"$'\n'
  done
  printf '%s' "$out"
}

echo "== L7.0 reference data"

# 0. generated function is fresh relative to the seeders
if ${PHP:-php} "$ROOT/scripts/generate-reference-data.php" --check >/dev/null 2>&1; then
  pass "generated _pay_ensure_reference_data() matches the seeders"
else
  fail "generated _pay_ensure_reference_data() is stale (run scripts/generate-reference-data.php)"
fi

# A. fresh database: schema + seeders loaded the way the gateway does on create.
new_db paytest_ref_fresh
load_schema paytest_ref_fresh || fail "fresh schema load"
FRESH="$(fingerprint paytest_ref_fresh)"

# a healthy database needs nothing
INS=$(q paytest_ref_fresh "SELECT coalesce(sum(rows_inserted),0) FROM _pay_ensure_reference_data()")
check "fresh DB: ensure inserts nothing" "0" "$INS"
check "fresh DB: reference rows unchanged after ensure" "$FRESH" "$(fingerprint paytest_ref_fresh)"

# B. a database created before the package existed: unrelated tables present,
#    package tables + functions staged, but the gateway never seeded them.
new_db paytest_ref_old
q paytest_ref_old "CREATE TABLE legacy_app_table (id serial primary key, note text)" >/dev/null
q paytest_ref_old "INSERT INTO legacy_app_table (note) VALUES ('keep me')" >/dev/null
load_schema paytest_ref_old --no-seeders || fail "old-db schema load"
check "old DB: tables are empty before ensure" "0" "$(q paytest_ref_old 'SELECT count(*) FROM inv_gst_state_codes')"
q paytest_ref_old "SELECT * FROM _pay_ensure_reference_data()" >/dev/null
check "old DB: converges to the fresh fingerprint" "$FRESH" "$(fingerprint paytest_ref_old)"
check "old DB: unrelated data untouched" "keep me" "$(q paytest_ref_old 'SELECT note FROM legacy_app_table')"
INS=$(q paytest_ref_old "SELECT coalesce(sum(rows_inserted),0) FROM _pay_ensure_reference_data()")
check "old DB: second run inserts nothing" "0" "$INS"
check "old DB: second run changes nothing" "$FRESH" "$(fingerprint paytest_ref_old)"

# C. partially applied earlier: the real-world shape is a seeder that stopped
#    after its first row, an empty table elsewhere, plus deliberate local edits.
new_db paytest_ref_partial
load_schema paytest_ref_partial || fail "partial-db schema load"
q paytest_ref_partial "DELETE FROM inv_outbox_intimation_statuses" >/dev/null
q paytest_ref_partial "DELETE FROM inv_invoice_status_transitions" >/dev/null
q paytest_ref_partial "DELETE FROM inv_invoice_statuses WHERE status <> 'draft'" >/dev/null
ALIASES_DELETED=$(q paytest_ref_partial "SELECT count(*) FROM inv_gst_state_name_aliases WHERE alias > 'm'")
q paytest_ref_partial "DELETE FROM inv_gst_state_name_aliases WHERE alias > 'm'" >/dev/null
q paytest_ref_partial "DELETE FROM inv_gst_config" >/dev/null
# local edits that must survive: a deployment's own checkout endpoint, and the
# India rule re-prioritised + disabled (must NOT be re-created as a duplicate).
q paytest_ref_partial "UPDATE inv_gateways SET checkout_endpoint='https://pay.local.test' WHERE code='razorpay'" >/dev/null
q paytest_ref_partial "UPDATE inv_gateway_routing_rules SET priority=20, is_active=false WHERE match_country_code='IN'" >/dev/null
# the export rule deleted outright: that one MUST come back.
q paytest_ref_partial "DELETE FROM inv_gateway_routing_rules WHERE match_country_code IS NULL" >/dev/null
GOT=$(q paytest_ref_partial "SELECT string_agg(table_name || '=' || rows_inserted, ',' ORDER BY table_name COLLATE \"C\") FROM _pay_ensure_reference_data() WHERE rows_inserted > 0")
check "partial DB: exactly the damaged tables got exactly the missing rows" \
  "inv_gateway_routing_rules=1,inv_gst_config=12,inv_gst_state_name_aliases=$ALIASES_DELETED,inv_invoice_status_transitions=6,inv_invoice_statuses=5,inv_outbox_intimation_statuses=1" "$GOT"
check "partial DB: local checkout endpoint preserved" "https://pay.local.test" "$(q paytest_ref_partial "SELECT checkout_endpoint FROM inv_gateways WHERE code='razorpay'")"
check "partial DB: re-prioritised/disabled IN rule not duplicated" "1" "$(q paytest_ref_partial "SELECT count(*) FROM inv_gateway_routing_rules WHERE match_country_code='IN'")"
check "partial DB: IN rule kept its local priority" "20" "$(q paytest_ref_partial "SELECT priority FROM inv_gateway_routing_rules WHERE match_country_code='IN'")"
check "partial DB: deleted export rule restored" "1" "$(q paytest_ref_partial "SELECT count(*) FROM inv_gateway_routing_rules WHERE match_country_code IS NULL AND gateway_code='paypal'")"
# restore the two local edits to compare the rest against fresh
q paytest_ref_partial "UPDATE inv_gateways SET checkout_endpoint='https://pay.example.com' WHERE code='razorpay'" >/dev/null
q paytest_ref_partial "UPDATE inv_gateway_routing_rules SET priority=10, is_active=true WHERE match_country_code='IN'" >/dev/null
check "partial DB: converges to the fresh fingerprint" "$FRESH" "$(fingerprint paytest_ref_partial)"
INS=$(q paytest_ref_partial "SELECT coalesce(sum(rows_inserted),0) FROM _pay_ensure_reference_data()")
check "partial DB: second run inserts nothing" "0" "$INS"

# D. drift guard in the data direction: wipe every reference table in a fresh
#    DB, rebuild ONLY via the function, and compare with the seeders' result.
new_db paytest_ref_wipe
load_schema paytest_ref_wipe || fail "wipe-db schema load"
for t in $TABLES_REV; do q paytest_ref_wipe "DELETE FROM $t" >/dev/null; done
q paytest_ref_wipe "SELECT * FROM _pay_ensure_reference_data()" >/dev/null
check "function data == seeder data (full rebuild from empty)" "$FRESH" "$(fingerprint paytest_ref_wipe)"

# F. no placeholder endpoint is ever live: gateways arrive inactive, by seeder and by function alike
check "fresh DB: seeded gateways are inactive" "0" "$(q paytest_ref_fresh 'SELECT count(*) FROM inv_gateways WHERE is_active')"
new_db paytest_ref_gw
load_schema paytest_ref_gw --no-seeders || fail "gw-db schema load"
q paytest_ref_gw "SELECT * FROM _pay_ensure_reference_data()" >/dev/null
check "ensure: gateways it inserts are inactive" "2,0" "$(q paytest_ref_gw 'SELECT count(*) || chr(44) || count(*) FILTER (WHERE is_active) FROM inv_gateways')"
check "slabs include 40% (GST 2.0) and still the legacy 12/28" "t" "$(q paytest_ref_gw "SELECT bool_and(r IN (SELECT rate FROM inv_gst_rate_slabs)) FROM unnest(ARRAY[0.05,0.12,0.18,0.28,0.40]::numeric[]) r")"
check "legacy slabs are marked in config" "0.12,0.28" "$(q paytest_ref_gw "SELECT inv_gst_config_text('legacy_rate_slabs')")"
drop_db paytest_ref_gw

# E. the 14 reference tables are exactly the ones the function reports on.
check "function reports exactly the 15 reference tables" "15" "$(q paytest_ref_fresh 'SELECT count(*) FROM _pay_ensure_reference_data()')"

for d in paytest_ref_fresh paytest_ref_old paytest_ref_partial paytest_ref_wipe; do drop_db $d; done
finish "L7.0 reference data"
