-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _pay_apply_schema_upgrades
--
-- Brings the SHAPE of tables that ALREADY EXIST in a consumer's database up to this
-- release's table definitions. Additive and idempotent: running it on a fresh
-- database, on an up-to-date one, or twice in a row changes nothing.
--
-- WHY THIS EXISTS
-- The StoneScriptDB Gateway creates a table from its file only when the table is
-- missing. It never alters a table that already exists (a new column, a relaxed
-- NOT NULL or a new index in a table file is reported as a "safe change" but is not
-- applied; confirmed by rehearsal on gateway 4.6.7). Without this function a database
-- that holds invoices from an earlier release would never receive the new columns.
-- New TABLES need nothing: the gateway creates them.
--
-- HOW A CONSUMER USES IT
-- One platform migration, together with the reference-data one:
--
--     SELECT * FROM _pay_apply_schema_upgrades();
--     SELECT * FROM _pay_ensure_reference_data();
--
-- The gateway deploys functions BEFORE it runs migrations, so triggers installed by
-- this release are live for an instant before the columns they read exist. Run the
-- migrate at a quiet moment (or before swapping in new application code); a write in
-- that window fails loudly and retries, it never corrupts.
--
-- Rules for whoever extends it: only additive changes (ADD COLUMN IF NOT EXISTS,
-- relaxing NOT NULL, CREATE INDEX IF NOT EXISTS, guarded ADD CONSTRAINT). Never drop,
-- retype or rewrite data here. Each step mirrors its table file exactly (same
-- constraint and index names), which tests/shell/l7_1_numbering.sh proves by comparing an
-- upgraded database to a fresh one.
--
-- It also back-fills mode on legacy invoices (see below).
-- Returns one row per change it applied (none when everything was already current).
CREATE OR REPLACE FUNCTION _pay_apply_schema_upgrades()
RETURNS TABLE (change TEXT) AS $$
DECLARE
    v_col RECORD;
    v_n   BIGINT;
BEGIN
    -- ---- L7.1: numbering + snapshot columns on inv_invoices ----
    IF to_regclass('inv_invoices') IS NOT NULL THEN
        FOR v_col IN
            SELECT * FROM (VALUES
                ('issuer_id',                  'BIGINT REFERENCES inv_issuers(id)'),
                ('series_id',                  'BIGINT REFERENCES inv_series(id)'),
                ('fy_label',                   'TEXT'),
                ('number_seq',                 'BIGINT'),
                ('mode',                       'TEXT CHECK (mode IN (''live'', ''test''))'),
                ('issue_date',                 'DATE'),
                ('seller_legal_name',          'TEXT'),
                ('seller_gstin',               'TEXT'),
                ('seller_registration_status', 'TEXT'),
                ('seller_state_code',          'TEXT'),
                ('seller_address',             'TEXT'),
                ('buyer_legal_name',           'TEXT'),
                ('buyer_gstin',                'TEXT'),
                ('buyer_registration_status',  'TEXT'),
                ('buyer_state_code',           'TEXT')
            ) AS t(col, ddl)
        LOOP
            IF NOT EXISTS (SELECT 1 FROM pg_attribute
                            WHERE attrelid = to_regclass('inv_invoices') AND attname = v_col.col AND NOT attisdropped) THEN
                EXECUTE format('ALTER TABLE inv_invoices ADD COLUMN %I %s', v_col.col, v_col.ddl);
                change := 'inv_invoices.' || v_col.col || ' added';
                RETURN NEXT;
            END IF;
        END LOOP;

        -- a series invoice opened as a draft has no number until it is issued
        IF EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = to_regclass('inv_invoices') AND attname = 'invoice_number' AND attnotnull) THEN
            ALTER TABLE inv_invoices ALTER COLUMN invoice_number DROP NOT NULL;
            change := 'inv_invoices.invoice_number is now nullable (drafts)';
            RETURN NEXT;
        END IF;

        IF to_regclass('inv_invoices_series_serial') IS NULL THEN
            CREATE UNIQUE INDEX inv_invoices_series_serial
                ON inv_invoices (series_id, fy_label, number_seq) WHERE series_id IS NOT NULL AND number_seq IS NOT NULL;
            change := 'index inv_invoices_series_serial created';
            RETURN NEXT;
        END IF;
        IF to_regclass('inv_invoices_issuer') IS NULL THEN
            CREATE INDEX inv_invoices_issuer ON inv_invoices (issuer_id) WHERE issuer_id IS NOT NULL;
            change := 'index inv_invoices_issuer created';
            RETURN NEXT;
        END IF;

        -- Legacy invoices (issued before the mode column existed) have mode NULL. Every mode check treats
        -- NULL as live, but make it explicit and queryable: a legacy row is 'test' only when it is PROVABLY
        -- test (its number carries the TEST prefix the old test series required); everything else is live.
        -- Only legacy rows (series_id NULL); idempotent.
        UPDATE inv_invoices SET mode = CASE WHEN upper(left(invoice_number, 4)) = 'TEST' THEN 'test' ELSE 'live' END
         WHERE mode IS NULL AND series_id IS NULL AND invoice_number IS NOT NULL;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        IF v_n > 0 THEN
            change := v_n || ' legacy invoice(s) back-filled with mode (live, or test when TEST-numbered)';
            RETURN NEXT;
        END IF;
    END IF;

    -- ---- L7.4: columns and constraints added after a first build (a database that got a pre-release build upgrades cleanly) ----
    IF to_regclass('ent_entitlements') IS NOT NULL THEN
        FOR v_col IN SELECT * FROM (VALUES
            ('billing_profile',    'JSONB'),
            ('next_billing_at',    'TIMESTAMPTZ'),
            ('billing_failures',   'INTEGER NOT NULL DEFAULT 0'),
            ('billing_retry_at',   'TIMESTAMPTZ'),
            ('billing_last_error', 'TEXT')
        ) AS t(col, ddl)
        LOOP
            IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'ent_entitlements' AND column_name = v_col.col) THEN
                EXECUTE format('ALTER TABLE ent_entitlements ADD COLUMN %I %s', v_col.col, v_col.ddl);
                change := 'column ent_entitlements.' || v_col.col || ' added';
                RETURN NEXT;
            END IF;
        END LOOP;
    END IF;
    -- CHECK constraints whose value list grew: replace them only when the stored definition lacks the new value (idempotent)
    IF to_regclass('ent_activations') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ent_activations_kind_check' AND conrelid = to_regclass('ent_activations')
                                                                  AND pg_get_constraintdef(oid) LIKE '%''mode''%') THEN
        ALTER TABLE ent_activations DROP CONSTRAINT IF EXISTS ent_activations_kind_check;
        ALTER TABLE ent_activations ADD CONSTRAINT ent_activations_kind_check CHECK (kind IN ('comp', 'payment', 'trial', 'enroll', 'migration', 'status', 'mode'));
        change := 'constraint ent_activations_kind_check widened (mode)';
        RETURN NEXT;
    END IF;

    -- ---- L7.5: wallet v2 / ledger columns and constraints added after a first build ----
    IF to_regclass('wlt_meters') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'wlt_meters' AND column_name = 'closed_at') THEN
        ALTER TABLE wlt_meters ADD COLUMN closed_at TIMESTAMPTZ;
        change := 'column wlt_meters.closed_at added';
        RETURN NEXT;
    END IF;
    IF to_regclass('wlt_meters') IS NOT NULL THEN
        FOR v_col IN SELECT * FROM (VALUES ('rate_num', 'BIGINT'), ('rate_den', 'BIGINT')) AS t(col, ddl) LOOP
            IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'wlt_meters' AND column_name = v_col.col) THEN
                EXECUTE format('ALTER TABLE wlt_meters ADD COLUMN %I %s', v_col.col, v_col.ddl);
                change := 'column wlt_meters.' || v_col.col || ' added';
                RETURN NEXT;
            END IF;
        END LOOP;
    END IF;
    IF to_regclass('wlt_meter_ticks') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'wlt_meter_ticks' AND column_name = 'superseded') THEN
        ALTER TABLE wlt_meter_ticks ADD COLUMN superseded BOOLEAN NOT NULL DEFAULT FALSE;
        change := 'column wlt_meter_ticks.superseded added';
        RETURN NEXT;
    END IF;
    IF to_regclass('wlt_grants') IS NOT NULL THEN
        FOR v_col IN SELECT * FROM (VALUES ('gateway_code', 'TEXT'), ('gateway_txn_ref', 'TEXT'), ('unit_price_pinned', 'BIGINT'), ('amount_paid', 'BIGINT NOT NULL DEFAULT 0'),
                                           ('request_hash', 'TEXT')) AS t(col, ddl) LOOP
            IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'wlt_grants' AND column_name = v_col.col) THEN
                EXECUTE format('ALTER TABLE wlt_grants ADD COLUMN %I %s', v_col.col, v_col.ddl);
                change := 'column wlt_grants.' || v_col.col || ' added';
                RETURN NEXT;
            END IF;
        END LOOP;
    END IF;
    IF to_regclass('ledger_txns') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ledger_txns_kind_check' AND conrelid = to_regclass('ledger_txns')
                                                              AND pg_get_constraintdef(oid) LIKE '%clawback%') THEN
        ALTER TABLE ledger_txns DROP CONSTRAINT IF EXISTS ledger_txns_kind_check;
        ALTER TABLE ledger_txns ADD CONSTRAINT ledger_txns_kind_check CHECK (kind IN ('topup', 'free_grant', 'opening', 'drain', 'forfeit', 'refund', 'reversal', 'clawback'));
        change := 'constraint ledger_txns_kind_check widened (refund, reversal, clawback)';
        RETURN NEXT;
    END IF;

    -- ---- L7.3: ageing-alert stamp on the refund queue (only if a pre-release build created the table without it) ----
    IF to_regclass('pay_refund_queue') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'pay_refund_queue' AND column_name = 'last_alert_at') THEN
        ALTER TABLE pay_refund_queue ADD COLUMN last_alert_at TIMESTAMPTZ;
        change := 'column pay_refund_queue.last_alert_at added';
        RETURN NEXT;
    END IF;
    RETURN;
END;
$$ LANGUAGE plpgsql;
