#!/usr/bin/env bash
# L7.5 upgrade: a database that got an EARLIER wallet build (the first wallet v2 tables, then the meter tables before they gained closed_at / superseded)
# must be brought to the current shape by _pay_apply_schema_upgrades(), and a second run must change nothing. The old table definitions are the fixtures in
# tests/fixtures/pre-release-wallet-first (ledger with the narrower kind list) and tests/fixtures/pre-release-wallet-meters (meters without closed_at/superseded).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== L7.5 upgrade from the earlier wallet builds"
new_db paytest_l75_old
new_db paytest_l75_new
load_schema paytest_l75_new || { fail "fresh schema load"; finish "L7.5 upgrade"; exit 1; }

F1="$ROOT/tests/fixtures/pre-release-wallet-first"
F2="$ROOT/tests/fixtures/pre-release-wallet-meters"
while IFS= read -r f; do
  case "$f" in
    */054_10_wlt_wallets.pgsql|*/054_11_wlt_grants.pgsql|*/054_12_wlt_drains.pgsql|*/054_13_ledger.pgsql) f="$F1/$(basename "$f")" ;;
    */054_15_wlt_meters.pgsql|*/054_16_wlt_meter_ticks.pgsql) f="$F2/$(basename "$f")" ;;
  esac
  $PSQL -v ON_ERROR_STOP=1 -d paytest_l75_old -q -f "$f" >/dev/null || { fail "old schema load at $f"; finish "L7.5 upgrade"; exit 1; }
done < <(schema_files)

shape() {
  q "$1" "SELECT string_agg(t || '.' || column_name || ':' || data_type || ':' || is_nullable || ':' || coalesce(column_default,''), ',' ORDER BY t, column_name)
                 || ' con=' || (SELECT string_agg(conrelid::regclass || '.' || conname || '=' || pg_get_constraintdef(oid), ';' ORDER BY conrelid::regclass::text, conname)
                                  FROM pg_constraint WHERE conrelid IN ('wlt_grants'::regclass, 'wlt_meters'::regclass, 'wlt_meter_ticks'::regclass, 'ledger_txns'::regclass) AND contype = 'c')
            FROM (SELECT table_name AS t, column_name, data_type, is_nullable, column_default FROM information_schema.columns
                   WHERE table_name IN ('wlt_grants', 'wlt_meters', 'wlt_meter_ticks', 'ledger_txns')) x"
}
check "the earlier-build fixtures really differ from the current shape" "t" "$([ "$(shape paytest_l75_old)" != "$(shape paytest_l75_new)" ] && echo t || echo f)"
q paytest_l75_old "INSERT INTO wlt_wallets (tenant_id, platform_code) VALUES ('00000000-0000-0000-0000-00000000bb01', 'oldplat')" >/dev/null
CHANGES=$(q paytest_l75_old "SELECT count(*) FROM _pay_apply_schema_upgrades()")
check "the upgrade reports its changes (meters.closed_at, ticks.superseded, the widened ledger kinds)" "3" "$CHANGES"
check "upgraded shape (columns, defaults, nullability, check constraints) equals a fresh database" "$(shape paytest_l75_new)" "$(shape paytest_l75_old)"
check "a second run changes nothing" "0" "$(q paytest_l75_old 'SELECT count(*) FROM _pay_apply_schema_upgrades()')"
check "a fresh database: the upgrade is a no-op" "0" "$(q paytest_l75_new 'SELECT count(*) FROM _pay_apply_schema_upgrades()')"
check "the old wallet row survived" "1" "$(q paytest_l75_old "SELECT count(*) FROM wlt_wallets WHERE platform_code = 'oldplat'")"

drop_db paytest_l75_old
drop_db paytest_l75_new
finish "L7.5 upgrade"
