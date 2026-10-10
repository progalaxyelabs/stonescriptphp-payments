#!/usr/bin/env bash
# L7.4 upgrade: a database that got the PRE-RELEASE entitlement build (tag-less commit 1053b42: ent tables without the billing back-off columns and with
# the narrower activation-kind constraint) must be brought to the current shape by _pay_apply_schema_upgrades(), and a second run must change nothing.
# The old table definitions are the fixtures in tests/fixtures/pre-release-1053b42 (so this test needs no old commit in the clone).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== L7.4 upgrade from the pre-release build"
new_db paytest_l74_old
new_db paytest_l74_new
load_schema paytest_l74_new || { fail "fresh schema load"; finish "L7.4 upgrade"; exit 1; }

# the old database: the current schema, but the three entitlement TABLES loaded from the pre-release fixtures
FIX="$ROOT/tests/fixtures/pre-release-1053b42"
while IFS= read -r f; do
  case "$f" in
    */053_10_ent_entitlements.pgsql) f="$FIX/053_10_ent_entitlements.pgsql" ;;
    */053_11_ent_activations.pgsql)  f="$FIX/053_11_ent_activations.pgsql" ;;
    */053_12_ent_billing_runs.pgsql) f="$FIX/053_12_ent_billing_runs.pgsql" ;;
  esac
  $PSQL -v ON_ERROR_STOP=1 -d paytest_l74_old -q -f "$f" >/dev/null || { fail "old schema load at $f"; finish "L7.4 upgrade"; exit 1; }
done < <(schema_files)

shape() {
  q "$1" "SELECT string_agg(t || '.' || column_name || ':' || data_type || ':' || is_nullable || ':' || coalesce(column_default,''), ',' ORDER BY t, column_name)
                 || ' con=' || (SELECT string_agg(conrelid::regclass || '.' || conname || '=' || pg_get_constraintdef(oid), ';' ORDER BY conrelid::regclass::text, conname)
                                  FROM pg_constraint WHERE conrelid IN ('ent_entitlements'::regclass, 'ent_activations'::regclass, 'ent_billing_runs'::regclass) AND contype = 'c')
            FROM (SELECT table_name AS t, column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_name IN ('ent_entitlements', 'ent_activations', 'ent_billing_runs')) x"
}
check "the pre-release fixture really differs from the current shape" "t" "$([ "$(shape paytest_l74_old)" != "$(shape paytest_l74_new)" ] && echo t || echo f)"

# data written by the old build survives the upgrade
q paytest_l74_old "INSERT INTO ent_entitlements (tenant_id, platform_code, product, status, plan_ref, started_at, current_period_end, source, updated_by)
                   VALUES ('00000000-0000-0000-0000-00000000aa01', 'oldplat', 'default', 'active', 'comp', now(), now() + interval '30 days', 'comp', 'old build')" >/dev/null
CHANGES=$(q paytest_l74_old "SELECT count(*) FROM _pay_apply_schema_upgrades()")
check "the upgrade reports its changes (3 billing columns + the widened kind constraint)" "4" "$CHANGES"
check "upgraded shape (columns, defaults, nullability, check constraints) equals a fresh database" "$(shape paytest_l74_new)" "$(shape paytest_l74_old)"
check "a second run changes nothing" "0" "$(q paytest_l74_old 'SELECT count(*) FROM _pay_apply_schema_upgrades()')"
check "a fresh database: the upgrade is a no-op" "0" "$(q paytest_l74_new 'SELECT count(*) FROM _pay_apply_schema_upgrades()')"
check "the old row survived, with the new columns at their defaults" "active,0" "$(q paytest_l74_old "SELECT status || ',' || billing_failures FROM ent_entitlements WHERE platform_code = 'oldplat'")"
check "the widened constraint accepts the new activation kind" "t" "$(q paytest_l74_old "SELECT (pg_get_constraintdef(oid) LIKE '%''mode''%')::text FROM pg_constraint WHERE conname = 'ent_activations_kind_check'" | sed 's/true/t/')"

drop_db paytest_l74_old
drop_db paytest_l74_new
finish "L7.4 upgrade"
