#!/usr/bin/env bash
# Gateway rehearsal: stages this package's schema the way a consuming platform
# does and drives a REAL StoneScriptDB Gateway through register / create /
# migrate on throwaway databases, to prove the schema deploys, redeploys and
# converges on:
#   A. a fresh database                       (gateway seeds at create)
#   B. a database that predates the package   (hazard reproduced, then fixed by
#                                              the one-line reference-data migration)
#   C. a partially seeded database            (rows removed behind its back)
#   D. a database holding the PREVIOUS RELEASE (git tag v0.1.1) with live invoices,
#      upgraded in place: new tables created, changed function signatures replaced,
#      _pay_apply_schema_upgrades() reshapes inv_invoices, rows untouched, and the
#      resulting schema equals the fresh database of scenario A, object for object
# and that a second and third migrate pass on each is a clean no-op (this is the
# self-reference-FK and identity-args redeploy check).
#
# NEVER point this at a shared or production gateway. It requires a gateway whose
# Postgres is a disposable instance.
#
#   GATEWAY_URL=http://127.0.0.1:19000 ADMIN_TOKEN=... \
#   PSQL='psql -h 127.0.0.1 -p 55432 -U postgres' WORK=/path/to/empty/scratch/dir \
#   bash tests/rehearsal/gateway_migrate.sh
#
# Needs: curl, tar, jq, psql. The gateway's database naming is
# {platform}_{schema_name}; this script derives the names itself.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../shell/lib.sh"

: "${GATEWAY_URL:?set GATEWAY_URL}" "${ADMIN_TOKEN:?set ADMIN_TOKEN}" "${WORK:?set WORK to an empty scratch dir}"
RUN="rh$(date +%s)"
mkdir -p "$WORK"

api() { # api <method> <path> <json-or-empty> [token] -> prints body, sets HTTP
  local method="$1" path="$2" body="${3:-}" token="${4:-}"
  local args=(-s -m 120 -o "$WORK/resp.json" -w '%{http_code}' -X "$method" "$GATEWAY_URL$path" -H 'Content-Type: application/json')
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  [ -n "$body" ] && args+=(-d "$body")
  HTTP=$(curl "${args[@]}")
}

# stage <dir> <with_payments:0|1> <migration_count> [src_root]
# src_root defaults to this checkout; scenario D passes an extracted older release.
stage() {
  local dir="$1" with="$2" nmig="$3" src="${4:-$ROOT/src}" b f
  mkdir -p "$dir/postgresql/tables" "$dir/postgresql/functions" "$dir/postgresql/seeders" "$dir/postgresql/types" "$dir/postgresql/migrations"
  # the platform's own pre-existing object
  printf 'CREATE TABLE legacy_app_table (\n    id SERIAL PRIMARY KEY,\n    note TEXT\n);\n' > "$dir/postgresql/tables/900_legacy_app_table.pgsql"
  if [ "$with" = 1 ]; then
    for b in tables functions seeders types; do
      while IFS= read -r f; do cp "$f" "$dir/postgresql/$b/"; done < <(find "$src" -path "*/Schema/$b/*.pgsql")
    done
  fi
  local i
  for i in $(seq 1 "$nmig"); do
    # the documented platform migration: reshape existing tables, converge reference data
    printf -- '-- platform migration: payments schema upgrade + reference data\nSELECT * FROM _pay_apply_schema_upgrades();\nSELECT * FROM _pay_ensure_reference_data();\n' \
      > "$dir/postgresql/migrations/$(printf '%03d' "$i")_payments_upgrade.pgsql"
  done
}

upload() { # upload <platform> <schema> <stagedir>
  tar -czf "$WORK/$2.tar.gz" -C "$3" postgresql
  HTTP=$(curl -s -m 120 -o "$WORK/resp.json" -w '%{http_code}' -X POST "$GATEWAY_URL/platform/$1/schema" \
    -F "schema_name=$2" -F "schema=@$WORK/$2.tar.gz")
}

declare -A TOKENS
TOKEN=""
use() { TOKEN="${TOKENS[$1]}"; }  # select the platform token for later calls
register() { # register <platform>
  api POST /platform/register "{\"platform\":\"$1\"}"
  [ "$HTTP" = 201 ] || [ "$HTTP" = 200 ] || { fail "register $1 (HTTP $HTTP): $(cat "$WORK/resp.json")"; return 1; }
  api POST /admin/platform-token "{\"platform\":\"$1\"}" "$ADMIN_TOKEN"
  TOKEN=$(jq -r .token "$WORK/resp.json")
  [ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { fail "platform token for $1 (HTTP $HTTP): $(cat "$WORK/resp.json")"; return 1; }
  TOKENS[$1]="$TOKEN"
}

create_db() { use "$1"; api POST /admin/database/create "{\"platform\":\"$1\",\"schema_name\":\"$2\"}" "$TOKEN"; }
migrate() { use "$1"; api POST /v2/migrate "{\"platform\":\"$1\",\"schema_name\":\"$2\"}" "$TOKEN"; }
dbname() { echo "$1_$2"; }
is2xx() { case "$HTTP" in 2??) echo 2xx ;; *) echo "HTTP $HTTP: $(cut -c1-300 "$WORK/resp.json")" ;; esac; }
msg() { jq -c '{status, error, message, migrations_applied, functions_updated}' "$WORK/resp.json" 2>/dev/null | cut -c1-400; }

TABLES="inv_gateways inv_gateway_routing_rules inv_invoice_statuses inv_invoice_status_transitions inv_outbox_directions inv_outbox_statuses inv_outbox_intimation_statuses inv_outbox_config inv_gst_state_codes inv_gst_state_name_aliases inv_gst_config inv_gst_rate_slabs inv_fx_reference_rates inv_tax_scheme"
counts() { local t n out=""; for t in $TABLES; do n=$(q "$1" "SELECT count(*) FROM $t" 2>/dev/null) || n="QUERY-FAILED"; out+="$t=$n"$'\n'; done; printf '%s' "$out"; }

echo "== gateway rehearsal ($(curl -s "$GATEWAY_URL/health" | jq -r .version)) run=$RUN"

# ---- A. fresh database ---------------------------------------------------
PA="${RUN}a"
register "$PA" || exit 1
stage "$WORK/A" 1 1
upload "$PA" main "$WORK/A"; check "A upload schema" 2xx "$(is2xx)"
create_db "$PA" main; check "A create database (gateway seeds)" 2xx "$(is2xx)"; echo "    $(msg)"
DBA=$(dbname "$PA" main)
EXPECT="$(counts "$DBA")"
check "A reference rows seeded at create (14 tables non-empty)" 14 "$(echo "$EXPECT" | grep -vc '=0$')"
for pass in 1 2 3; do
  migrate "$PA" main; check "A migrate pass $pass is a clean no-op" 200 "$HTTP"; echo "    $(msg)"
  check "A pass $pass verification" completed "$(jq -r .status "$WORK/resp.json")"
done
check "A counts unchanged after 3 migrate passes" "$EXPECT" "$(counts "$DBA")"

# ---- B. database that predates the package -------------------------------
PB="${RUN}b"
register "$PB" || exit 1
stage "$WORK/B0" 0 0
upload "$PB" main "$WORK/B0"; check "B0 upload legacy-only schema" 2xx "$(is2xx)"
create_db "$PB" main; check "B0 create legacy database" 2xx "$(is2xx)"
DBB=$(dbname "$PB" main)
q "$DBB" "INSERT INTO legacy_app_table (note) VALUES ('keep me')" >/dev/null

# B1: stage the package WITHOUT the reference-data migration (the hazard)
stage "$WORK/B1" 1 0
upload "$PB" main "$WORK/B1"; check "B1 upload package schema, no migration" 2xx "$(is2xx)"
migrate "$PB" main
echo "    HTTP $HTTP $(msg)"
STATUS1=$(jq -r .status "$WORK/resp.json")
if { [ "$HTTP" != 200 ] || [ "$STATUS1" != completed ]; } && grep -qi 'seeder' "$WORK/resp.json"; then
  pass "B1 hazard reproduced: migrate without the reference-data migration fails seeder verification"
else
  fail "B1 expected verification to fail without the migration, but it completed"
fi
# B2: add the one-line migration and migrate again
stage "$WORK/B2" 1 1
upload "$PB" main "$WORK/B2"; check "B2 upload schema + reference-data migration" 2xx "$(is2xx)"
migrate "$PB" main; check "B2 migrate converges" 200 "$HTTP"; echo "    $(msg)"
check "B2 verification passes" completed "$(jq -r .status "$WORK/resp.json")"
check "B2 counts identical to a fresh database" "$EXPECT" "$(counts "$DBB")"
check "B2 platform data untouched" "keep me" "$(q "$DBB" 'SELECT note FROM legacy_app_table')"
for pass in 2 3; do
  migrate "$PB" main; check "B migrate pass $pass is a clean no-op" 200 "$HTTP"
  check "B pass $pass verification" completed "$(jq -r .status "$WORK/resp.json")"
done
check "B counts unchanged after repeat passes" "$EXPECT" "$(counts "$DBB")"

# ---- C. partially seeded database ------------------------------------------
# Rows removed behind the gateway's back (children first), then a NEW migration
# file calls the function again, as a platform does after a package release.
q "$DBA" "DELETE FROM inv_outbox_intimation_statuses" >/dev/null
q "$DBA" "DELETE FROM inv_invoice_status_transitions" >/dev/null
q "$DBA" "DELETE FROM inv_invoice_statuses WHERE status <> 'draft'" >/dev/null
q "$DBA" "DELETE FROM inv_gst_state_name_aliases WHERE alias > 'm'" >/dev/null
q "$DBA" "DELETE FROM inv_gst_config" >/dev/null
migrate "$PA" main
echo "    HTTP $HTTP $(msg)"
if [ "$(jq -r .status "$WORK/resp.json")" != completed ] && grep -qi 'seeder' "$WORK/resp.json"; then pass "C damaged DB: plain migrate fails seeder verification"; else fail "C damaged DB unexpectedly verified or failed for another reason"; fi
stage "$WORK/C" 1 2
upload "$PA" main "$WORK/C"; check "C upload schema + second reference-data migration" 2xx "$(is2xx)"
migrate "$PA" main; check "C migrate converges" 200 "$HTTP"; echo "    $(msg)"
check "C verification passes" completed "$(jq -r .status "$WORK/resp.json")"
check "C counts identical to a fresh database" "$EXPECT" "$(counts "$DBA")"

# ---- D. in-place upgrade from the previous release -------------------------------
if git -C "$ROOT" rev-parse -q --verify v0.1.1^{commit} >/dev/null; then
  PD="${RUN}d"
  mkdir -p "$WORK/v011"
  git -C "$ROOT" archive v0.1.1 src | tar -x -C "$WORK/v011"
  register "$PD" || exit 1
  stage "$WORK/D0" 1 0 "$WORK/v011/src"
  upload "$PD" main "$WORK/D0"; check "D0 upload previous-release schema" 2xx "$(is2xx)"
  create_db "$PD" main; check "D0 create database from the previous release" 2xx "$(is2xx)"
  DBD=$(dbname "$PD" main)
  q "$DBD" "INSERT INTO legacy_app_table (note) VALUES ('keep me')" >/dev/null
  q "$DBD" "SELECT inv_issue_invoice('OLD-000001', '00000000-0000-0000-0000-0000000d0001', 'rhd', 'subscription', NULL,
        '2026-08-01', '2026-09-01', '2026-10-01', 'IN', 'Karnataka',
        ROW('Seller Pvt Ltd','29AAACX1234C1ZP','seller','regular','Karnataka','29')::inv_party_input,
        ROW('Buyer',NULL,'buyer','unregistered','Karnataka',NULL)::inv_party_input,
        'domestic', NULL, false, false, 'INR', NULL, NULL, '2026-09-01',
        ARRAY[ROW('Plan','998314','1','499.00',0.18,NULL,false)::inv_line_input], NULL, 'seed', '2026-09-01', 'issued')" >/dev/null
  q "$DBD" "SELECT inv_issue_invoice('OLD-000002', '00000000-0000-0000-0000-0000000d0001', 'rhd', 'subscription', NULL,
        '2026-08-01', '2026-09-01', '2026-10-01', 'IN', 'Karnataka',
        ROW('Seller Pvt Ltd','29AAACX1234C1ZP','seller','regular','Karnataka','29')::inv_party_input,
        ROW('Buyer',NULL,'buyer','unregistered','Karnataka',NULL)::inv_party_input,
        'domestic', NULL, false, false, 'INR', NULL, NULL, '2026-09-01',
        ARRAY[ROW('Plan','998314','1','999.00',0.18,NULL,false)::inv_line_input], NULL, 'seed', '2026-09-01', 'draft')" >/dev/null
  BEFORE_ROWS="$(q "$DBD" "SELECT string_agg(invoice_number || '/' || gross_total_minor || '/' || status, ',' ORDER BY invoice_number) FROM inv_invoices")"
  check "D0 two pre-existing invoices (one issued, one draft)" "OLD-000001/58882/issued,OLD-000002/117882/draft" "$BEFORE_ROWS"

  stage "$WORK/D1" 1 1
  upload "$PD" main "$WORK/D1"; check "D1 upload current schema + upgrade migration" 2xx "$(is2xx)"
  migrate "$PD" main; check "D1 in-place migrate succeeds" 200 "$HTTP"; echo "    $(msg)"
  check "D1 verification passes" completed "$(jq -r .status "$WORK/resp.json")"
  check "D1 the previous release's invoices are untouched" "$BEFORE_ROWS" \
    "$(q "$DBD" "SELECT string_agg(invoice_number || '/' || gross_total_minor || '/' || status, ',' ORDER BY invoice_number) FROM inv_invoices")"
  check "D1 platform data untouched" "keep me" "$(q "$DBD" 'SELECT note FROM legacy_app_table')"
  # whole-schema equivalence with the fresh database of scenario A, object for object
  fullshape() {
    q "$1" "SELECT 'cols=' || (SELECT md5(string_agg(table_name || '.' || column_name || ':' || data_type || ':' || is_nullable || ':' || coalesce(column_default,''), ',' ORDER BY table_name, column_name))
                                 FROM information_schema.columns WHERE table_schema='public')
              || ' idx=' || (SELECT md5(string_agg(indexname || '=' || indexdef, ';' ORDER BY indexname)) FROM pg_indexes WHERE schemaname='public')
              || ' con=' || (SELECT md5(string_agg(conrelid::regclass::text || '.' || conname || '=' || pg_get_constraintdef(oid), ';' ORDER BY conrelid::regclass::text, conname))
                               FROM pg_constraint WHERE connamespace = 'public'::regnamespace)
              || ' fns=' || (SELECT md5(string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ';' ORDER BY p.proname, pg_get_function_identity_arguments(p.oid)))
                               FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f')
              || ' trg=' || (SELECT md5(string_agg(c.relname || '.' || t.tgname, ';' ORDER BY c.relname, t.tgname))
                               FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid WHERE NOT t.tgisinternal AND c.relnamespace = 'public'::regnamespace)"
  }
  check "D1 columns, indexes, constraints, functions and triggers equal the fresh database" "$(fullshape "$DBA")" "$(fullshape "$DBD")"
  check "D1 exactly one inv_issue_invoice overload remains" 1 "$(q "$DBD" "SELECT count(*) FROM pg_proc WHERE proname='inv_issue_invoice'")"
  # the previous release's call shape (explicit number, 25 positional arguments) must still resolve: no 42725 "not unique" against the new signature
  OLDCALL=$(q "$DBD" "SELECT inv_issue_invoice('OLDSHAPE-000001', '00000000-0000-0000-0000-0000000d0001', 'rhd', 'subscription', NULL,
        '2026-08-01', '2026-09-01', '2026-10-01', 'IN', 'Karnataka',
        ROW('Seller Pvt Ltd','29AAACX1234C1ZP','seller','regular','Karnataka','29')::inv_party_input,
        ROW('Buyer',NULL,'buyer','unregistered','Karnataka',NULL)::inv_party_input,
        'domestic', NULL, false, false, 'INR', NULL, NULL, '2026-09-01',
        ARRAY[ROW('Plan','998314','1','499.00',0.18,NULL,false)::inv_line_input], NULL, 'seed', '2026-09-01', 'draft', p_mode => 'live') > 0" 2>&1)
  check "D1 the previous release's 25-argument call shape resolves on the new signature (no 42725 ambiguity)" "t" "$OLDCALL"
  q "$DBD" "DELETE FROM inv_invoice_lines WHERE invoice_id IN (SELECT id FROM inv_invoices WHERE invoice_number='OLDSHAPE-000001'); DELETE FROM inv_invoices WHERE invoice_number='OLDSHAPE-000001'" >/dev/null
  # the upgraded database issues lawful numbers: adopt over the existing series, then issue
  q "$DBD" "SELECT _inv_issuer_upsert('rhd-issuer','rhd',NULL,'Seller Pvt Ltd','regular','29AAACX1234C1ZP','29','x',false,'rehearsal')" >/dev/null
  q "$DBD" "SELECT _inv_series_create('rhd-old','rhd-issuer','invoice','live','OLD','-',6,false,'rehearsal')" >/dev/null
  q "$DBD" "SELECT * FROM _inv_series_adopt('rhd-old', NULL, 2, 'rehearsal: OLD-000001..2 already issued', 'rehearsal')" >/dev/null
  NEWNO=$(q "$DBD" "SELECT set_config('pay.issuing', 'on', true); SELECT o_invoice_number FROM _inv_series_allocate('rhd-old', now(), 'live')" | tail -1)
  check "D1 the first library number continues the old series" "OLD-000003" "$NEWNO"
  q "$DBD" "DELETE FROM inv_invoices WHERE invoice_number = 'OLD-000001'" >/dev/null 2>&1
  check "D1 an issued legacy invoice can no longer be deleted" 2 "$(q "$DBD" 'SELECT count(*) FROM inv_invoices')"
  for pass in 2 3; do
    migrate "$PD" main; check "D migrate pass $pass is a clean no-op" 200 "$HTTP"
    check "D pass $pass verification" completed "$(jq -r .status "$WORK/resp.json")"
  done
  check "D schema unchanged after repeat passes" "$(fullshape "$DBA")" "$(fullshape "$DBD")"
else
  fail "D tag v0.1.1 is not present in this checkout: the upgrade rehearsal cannot run"
fi

finish "gateway rehearsal"
