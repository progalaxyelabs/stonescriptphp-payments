-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: triggers using wlt_guard / ledger_balanced_check (054_49) and pay_no_truncate (035_24)
CREATE OR REPLACE TRIGGER wlt_grants_guard    BEFORE UPDATE OR DELETE ON wlt_grants           FOR EACH ROW EXECUTE FUNCTION wlt_guard();
CREATE OR REPLACE TRIGGER wlt_drains_guard    BEFORE UPDATE OR DELETE ON wlt_drains           FOR EACH ROW EXECUTE FUNCTION wlt_guard();
CREATE OR REPLACE TRIGGER wlt_alloc_guard     BEFORE UPDATE OR DELETE ON wlt_drain_allocations FOR EACH ROW EXECUTE FUNCTION wlt_guard();
CREATE OR REPLACE TRIGGER wlt_forfeits_guard  BEFORE UPDATE OR DELETE ON wlt_forfeits         FOR EACH ROW EXECUTE FUNCTION wlt_guard();
CREATE OR REPLACE TRIGGER ledger_txns_guard   BEFORE UPDATE OR DELETE ON ledger_txns          FOR EACH ROW EXECUTE FUNCTION wlt_guard();
CREATE OR REPLACE TRIGGER ledger_entries_guard BEFORE UPDATE OR DELETE ON ledger_entries      FOR EACH ROW EXECUTE FUNCTION wlt_guard();
CREATE OR REPLACE TRIGGER wlt_wallets_guard   BEFORE UPDATE OR DELETE ON wlt_wallets                    FOR EACH ROW EXECUTE FUNCTION wlt_guard();
CREATE OR REPLACE TRIGGER wlt_meters_guard    BEFORE UPDATE OR DELETE ON wlt_meters           FOR EACH ROW EXECUTE FUNCTION wlt_guard();
CREATE OR REPLACE TRIGGER wlt_ticks_guard     BEFORE UPDATE OR DELETE ON wlt_meter_ticks      FOR EACH ROW EXECUTE FUNCTION wlt_guard();
CREATE OR REPLACE TRIGGER wlt_packs_no_delete BEFORE DELETE ON wlt_packs                      FOR EACH ROW EXECUTE FUNCTION wlt_guard();
CREATE OR REPLACE TRIGGER pay_config_wallet_unit_guard BEFORE UPDATE OR DELETE ON pay_config FOR EACH ROW EXECUTE FUNCTION wlt_config_guard();
CREATE OR REPLACE TRIGGER wlt_wallets_no_truncate    BEFORE TRUNCATE ON wlt_wallets           FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
CREATE OR REPLACE TRIGGER wlt_grants_no_truncate     BEFORE TRUNCATE ON wlt_grants            FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
CREATE OR REPLACE TRIGGER wlt_drains_no_truncate     BEFORE TRUNCATE ON wlt_drains            FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
CREATE OR REPLACE TRIGGER wlt_alloc_no_truncate      BEFORE TRUNCATE ON wlt_drain_allocations FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
CREATE OR REPLACE TRIGGER wlt_forfeits_no_truncate   BEFORE TRUNCATE ON wlt_forfeits          FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
CREATE OR REPLACE TRIGGER wlt_meters_no_truncate     BEFORE TRUNCATE ON wlt_meters            FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
CREATE OR REPLACE TRIGGER wlt_ticks_no_truncate      BEFORE TRUNCATE ON wlt_meter_ticks       FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
CREATE OR REPLACE TRIGGER wlt_packs_no_truncate      BEFORE TRUNCATE ON wlt_packs             FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
CREATE OR REPLACE TRIGGER ledger_txns_no_truncate    BEFORE TRUNCATE ON ledger_txns           FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
CREATE OR REPLACE TRIGGER ledger_entries_no_truncate BEFORE TRUNCATE ON ledger_entries        FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
-- a constraint trigger has no CREATE OR REPLACE form, so it is created once, guarded (this file is re-applied on every deploy)
DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'ledger_entries_balanced' AND tgrelid = 'ledger_entries'::regclass) THEN
        CREATE CONSTRAINT TRIGGER ledger_entries_balanced
            AFTER INSERT ON ledger_entries DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ledger_balanced_check();
    END IF;
END
$do$;
