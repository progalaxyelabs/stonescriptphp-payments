-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _pay_ensure_reference_data
--
-- GENERATED FILE - do not edit by hand.
--   regenerate: php scripts/generate-reference-data.php
--   freshness : php scripts/generate-reference-data.php --check   (also a test)
-- Source of truth: the reference-data seeders under src/**/Schema/seeders/.
--
-- WHY THIS EXISTS
-- The StoneScriptDB Gateway seeds reference data only when it CREATES a
-- database. A migrate of an existing database merely VERIFIES the seeder rows
-- and refuses ("MISSING SEEDER RECORDS") when any are absent, so a database
-- that was created before this package was staged, or that was only partly
-- seeded earlier, can never reach a verified state on its own.
--
-- WHAT IT DOES
-- Inserts every reference row that is missing, in foreign-key order, and
-- nothing else:
--   * Existing rows are never updated or deleted, so a local edit (for example
--     a deployment's own gateway checkout endpoint) is preserved.
--   * Routing rules are matched on (country, gateway), not on priority or
--     is_active, so a locally re-prioritised or disabled rule is not
--     re-created as a duplicate.
--   * Running it again changes nothing.
-- Returns one row per table with the number of rows it inserted (all zero on a
-- healthy database; a non-zero count tells an operator rows were missing).
--
-- HOW A CONSUMER USES IT
-- Add one migration file to the platform's own migrations (the gateway runs
-- migrations after tables and functions are deployed and before it verifies
-- the seeders):
--
--     SELECT * FROM _pay_ensure_reference_data();
--
-- A release of this package that adds reference rows needs a new such
-- migration in the consuming platform, because the gateway applies a
-- migration file once.
--
-- INTERNAL (leading underscore): not an application entry point. It is run by a platform migration or by an operator in
-- psql, never by request code; the StoneScriptDB Gateway refuses to /call names that start with an underscore.
-- Not a hot-path function.
CREATE OR REPLACE FUNCTION _pay_ensure_reference_data()
RETURNS TABLE (table_name TEXT, rows_inserted BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_n     BIGINT;
    v_total BIGINT := 0;
BEGIN
    -- inv_gateways  (from 034_30_inv_gateways.pgsql)
    INSERT INTO inv_gateways (code, display_name, settlement_currency, checkout_endpoint, is_active, created_at, created_by) VALUES
    ('razorpay', 'Razorpay',
        'INR', 'https://pay.example.com',
        false, '2026-01-01', 'seed'),   -- example central pay domain (adopter MUST override this row); Razorpay Standard Checkout
    ('paypal', 'PayPal',
        'USD', 'https://www.paypal.com/invoice',
        false, '2026-01-01', 'seed')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    table_name := 'inv_gateways'; rows_inserted := v_n; RETURN NEXT;

    -- inv_gateway_routing_rules  (from 034_31_inv_gateway_routing_rules.pgsql)
    INSERT INTO inv_gateway_routing_rules (match_country_code, is_export, gateway_code, priority, note, is_active, created_at, created_by)
    SELECT 'IN', false, 'razorpay', 10, 'India billing address -> Razorpay (INR domestic rail).', true, '2026-01-01', 'seed'
    WHERE NOT EXISTS (SELECT 1 FROM inv_gateway_routing_rules x WHERE x.match_country_code IS NOT DISTINCT FROM 'IN' AND x.gateway_code IS NOT DISTINCT FROM 'razorpay')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_total := v_total + v_n;
    INSERT INTO inv_gateway_routing_rules (match_country_code, is_export, gateway_code, priority, note, is_active, created_at, created_by)
    SELECT NULL, true, 'paypal', 100, 'Any non-India (export) billing address -> PayPal (USD, export services only for now).', true, '2026-01-01', 'seed'
    WHERE NOT EXISTS (SELECT 1 FROM inv_gateway_routing_rules x WHERE x.match_country_code IS NOT DISTINCT FROM NULL AND x.gateway_code IS NOT DISTINCT FROM 'paypal')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_total := v_total + v_n;
    table_name := 'inv_gateway_routing_rules'; rows_inserted := v_total; RETURN NEXT; v_total := 0;

    -- inv_invoice_statuses  (from 034_32_inv_invoice_statuses.pgsql)
    INSERT INTO inv_invoice_statuses (status, is_terminal, note) VALUES
    ('draft',     false, 'Created, not yet issued to the customer.'),
    ('issued',    false, 'Issued (legal document dated); awaiting the due date.'),
    ('due',       false, 'Payable now; postpaid model turns the account read-only until paid.'),
    ('paid',      true,  'Settled by exactly one successful payment; receipt downloadable.'),
    ('void',      false, 'Cancelled after issue (e.g. a correction/backfill). Not payable.'),
    ('cancelled', true,  'Cancelled before it ever became payable.')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    table_name := 'inv_invoice_statuses'; rows_inserted := v_n; RETURN NEXT;

    -- inv_invoice_status_transitions  (from 034_33_inv_invoice_status_transitions.pgsql)
    INSERT INTO inv_invoice_status_transitions (from_status, to_status, note) VALUES
    ('draft',  'issued',    'Issue the drafted invoice.'),
    ('draft',  'cancelled', 'Abandon a draft before issue.'),
    ('issued', 'due',       'Due date reached — becomes payable.'),
    ('issued', 'void',      'Void an issued invoice (correction).'),
    ('due',    'paid',      'Settled by a successful payment (ONLY via inv_record_payment).'),
    ('due',    'void',      'Void a due invoice (correction).')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    table_name := 'inv_invoice_status_transitions'; rows_inserted := v_n; RETURN NEXT;

    -- inv_outbox_directions  (from 037_31_inv_outbox_directions.pgsql)
    INSERT INTO inv_outbox_directions (direction, note) VALUES
    ('to_central', 'PRODUCT -> CENTRAL. Forward intimation: an invoice was issued at the product; central (merchant-of-record + CRM) must learn of it.'),
    ('to_product', 'CENTRAL -> PRODUCT. Reverse sync: central captured the payment; the product must learn it is paid so it can lift read-only.')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    table_name := 'inv_outbox_directions'; rows_inserted := v_n; RETURN NEXT;

    -- inv_outbox_statuses  (from 037_30_inv_outbox_statuses.pgsql)
    INSERT INTO inv_outbox_statuses (status, is_terminal, is_claimable, note) VALUES
    ('pending',   false, true,  'Enqueued, never yet attempted; claimable as soon as next_attempt_at <= as-of.'),
    ('failed',    false, true,  'Last attempt errored; will be RE-claimed once next_attempt_at (backoff) <= as-of. Retry state, NOT a drop.'),
    ('delivered', true,  false, 'Applied at the far side and acknowledged. Terminal SUCCESS.'),
    ('dead',      true,  false, 'Retries exhausted (attempts >= max_attempts). Terminal; surfaced for ops, never silently dropped.')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    table_name := 'inv_outbox_statuses'; rows_inserted := v_n; RETURN NEXT;

    -- inv_outbox_intimation_statuses  (from 037_32_inv_outbox_intimation_statuses.pgsql)
    INSERT INTO inv_outbox_intimation_statuses (invoice_status, direction, event_type, note) VALUES
    ('issued', 'to_central', 'invoice_issued', 'Invoice issued at the product -> intimate central immediately, atomically, exactly once.')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    table_name := 'inv_outbox_intimation_statuses'; rows_inserted := v_n; RETURN NEXT;

    -- inv_outbox_config  (from 037_33_inv_outbox_config.pgsql)
    INSERT INTO inv_outbox_config (id, max_attempts, created_at, created_by) VALUES
    (1, 8, '2026-01-01', 'seed')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    table_name := 'inv_outbox_config'; rows_inserted := v_n; RETURN NEXT;

    -- inv_gst_state_codes  (from 025_31_inv_gst_state_codes.pgsql)
    INSERT INTO inv_gst_state_codes (code, canonical_name) VALUES
    ('01','Jammu and Kashmir'), ('02','Himachal Pradesh'), ('03','Punjab'),
    ('04','Chandigarh'), ('05','Uttarakhand'), ('06','Haryana'), ('07','Delhi'),
    ('08','Rajasthan'), ('09','Uttar Pradesh'), ('10','Bihar'), ('11','Sikkim'),
    ('12','Arunachal Pradesh'), ('13','Nagaland'), ('14','Manipur'), ('15','Mizoram'),
    ('16','Tripura'), ('17','Meghalaya'), ('18','Assam'), ('19','West Bengal'),
    ('20','Jharkhand'), ('21','Odisha'), ('22','Chhattisgarh'), ('23','Madhya Pradesh'),
    ('24','Gujarat'), ('25','Daman and Diu'),
    ('26','Dadra and Nagar Haveli and Daman and Diu'),
    ('27','Maharashtra'), ('29','Karnataka'), ('30','Goa'), ('31','Lakshadweep'),
    ('32','Kerala'), ('33','Tamil Nadu'), ('34','Puducherry'),
    ('35','Andaman and Nicobar Islands'), ('36','Telangana'), ('37','Andhra Pradesh'),
    ('38','Ladakh'), ('96','Other Country'), ('97','Other Territory')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    table_name := 'inv_gst_state_codes'; rows_inserted := v_n; RETURN NEXT;

    -- inv_gst_state_name_aliases  (from 025_32_inv_gst_state_name_aliases.pgsql)
    INSERT INTO inv_gst_state_name_aliases (alias, code) VALUES
    ('jammu and kashmir','01'), ('jammu & kashmir','01'), ('jammu kashmir','01'),
    ('himachal pradesh','02'),
    ('punjab','03'),
    ('chandigarh','04'),
    ('uttarakhand','05'), ('uttaranchal','05'),
    ('haryana','06'),
    ('delhi','07'), ('nct of delhi','07'), ('new delhi','07'),
    ('rajasthan','08'),
    ('uttar pradesh','09'),
    ('bihar','10'),
    ('sikkim','11'),
    ('arunachal pradesh','12'),
    ('nagaland','13'),
    ('manipur','14'),
    ('mizoram','15'),
    ('tripura','16'),
    ('meghalaya','17'),
    ('assam','18'),
    ('west bengal','19'),
    ('jharkhand','20'),
    ('odisha','21'), ('orissa','21'),
    ('chhattisgarh','22'), ('chattisgarh','22'),
    ('madhya pradesh','23'),
    ('gujarat','24'),
    ('daman and diu','25'), ('daman & diu','25'),
    ('dadra and nagar haveli','26'), ('dadra & nagar haveli','26'),
    ('dadra and nagar haveli and daman and diu','26'),
    ('maharashtra','27'),
    ('karnataka','29'), ('karnataka (old)','29'),
    ('goa','30'),
    ('lakshadweep','31'),
    ('kerala','32'),
    ('tamil nadu','33'),
    ('puducherry','34'), ('pondicherry','34'),
    ('andaman and nicobar islands','35'), ('andaman & nicobar islands','35'),
    ('andaman and nicobar','35'),
    ('telangana','36'),
    ('andhra pradesh','37'),
    ('ladakh','38'),
    ('other country','96'), ('outside india','96'),
    ('other territory','97')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    table_name := 'inv_gst_state_name_aliases'; rows_inserted := v_n; RETURN NEXT;

    -- inv_gst_config  (from 026_31_inv_gst_config.pgsql)
    INSERT INTO inv_gst_config (config_key, config_value, note) VALUES
    ('invoice_number_max_length', '16',
        'Invoice number: at most sixteen characters.'),
    ('invoice_number_charset_regex', '^[A-Za-z0-9/ -]+$',
        'Invoice number charset: alphanumeric plus "-", "/", and a literal space.'),
    ('round_off_max_minor_units', '10000',
        'Rounding-adjustment range is -99.99..+99.99 rupees = strictly < 10000 paisa.'),
    ('gstin_shape_regex', '^\d{2}[A-Z]{5}\d{4}[A-Z][0-9A-Z]Z[0-9A-Z]$',
        'The 15-character GSTIN shape (review CRITICAL 1).'),
    ('composition_legend', 'Composition taxable person, not eligible to collect tax on supplies',
        'Legend for a composition-scheme bill_of_supply.'),
    ('no_itc_note', 'No tax has been charged on this document. No input tax credit is available against it.',
        'Printed on every no-tax (bill_of_supply) document (review W6a).'),
    ('title_tax_invoice', 'Tax Invoice', 'Caption for a tax invoice.'),
    ('title_bill_of_supply', 'Bill of Supply', 'Caption for a bill of supply (registered/composition seller).'),
    ('title_unregistered_invoice', 'Invoice',
        'An unregistered seller''s document is a plain commercial invoice, not a tax-caption document.'),
    ('legacy_rate_slabs', '0.12,0.28',
        'Slabs still accepted for historical documents but retired for new ones (GST 2.0). CA to confirm.'),
    ('issue_date_window_days_live', '0',
        'A LIVE series-numbered invoice must be dated today (IST) +/- this many days: 0 = the current IST calendar day only. Live documents are dated when they are issued; history comes in through the explicit-number import path, which is exempt.'),
    ('issue_date_window_days_test', '7',
        'The same window for TEST series, wider so sandbox flows and demos can post-date or back-date. A test document carries a TEST number and never reaches the books.')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    table_name := 'inv_gst_config'; rows_inserted := v_n; RETURN NEXT;

    -- inv_gst_rate_slabs  (from 026_32_inv_gst_rate_slabs.pgsql)
    INSERT INTO inv_gst_rate_slabs (rate) VALUES
    (0), (0.0025), (0.03), (0.05), (0.12), (0.18), (0.28), (0.40)
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    table_name := 'inv_gst_rate_slabs'; rows_inserted := v_n; RETURN NEXT;

    -- inv_fx_reference_rates  (from 032_31_inv_fx_reference_rates.pgsql)
    INSERT INTO inv_fx_reference_rates (currency, rate_date, rate_per_unit_inr, source) VALUES
    ('USD', '2026-09-13', 95.7245, 'RBI reference rate')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    table_name := 'inv_fx_reference_rates'; rows_inserted := v_n; RETURN NEXT;

    -- inv_tax_scheme  (from 033_02_inv_tax_scheme_seed.pgsql)
    INSERT INTO inv_tax_scheme (billing_country_code, scheme_type, display_name, is_active, created_by) VALUES
    ('IN', 'in_gst', 'India GST', TRUE, 'system:seed')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    table_name := 'inv_tax_scheme'; rows_inserted := v_n; RETURN NEXT;

    -- pay_config  (from 051_31_pay_config.pgsql)
    INSERT INTO pay_config (config_key, config_value, note) VALUES
    ('raw_payload_retention_months', '13',
        'Raw webhook bodies are redacted after this many months (DPDP Rules 2025 one-year floor + buffer). CA/legal to confirm.'),
    ('accounting_record_retention_years', '8',
        'Invoices, payments and buyer snapshots are never redacted by the payload job (Companies Act s.128). CA/legal to confirm.'),
    ('webhook_max_attempts', '8',
        'Attempts after which a still-failing inbox row is declared dead.'),
    ('webhook_dead_after_days', '14',
        'Age in days after which a still-open inbox row is declared dead on its next failure.'),
    ('webhook_backoff_base_seconds', '60',
        'First retry delay; doubles with every attempt.'),
    ('webhook_backoff_cap_seconds', '21600',
        'Upper bound of the retry delay (6 hours).'),
    ('refund_queue_alert_after_days', '3',
        'An open pay_refund_queue entry older than this many days raises an ageing alert: real money must not sit unrefunded unnoticed.'),
    ('refund_queue_alert_repeat_hours', '24',
        'An open entry that stays open is re-alerted at most this often.'),
    ('ent_past_due_after_days', '0',
        'A postpaid entitlement is past_due (writes still allowed, a warning) once an invoice is unpaid this many days after its due date.'),
    ('ent_read_only_after_days', '30',
        'A postpaid entitlement goes read-only once an invoice is unpaid this many days after its due date (billing model: 30 days). Paying restores it at once.'),
    ('ent_missing_mode', 'read_only',
        'What a tenant with NO entitlement row gets: read_only (the framework default) or allow.'),
    ('pay_clock_skew_seconds', '300',
        'A caller-supplied moment (a comp, a trial start, a drain, a sweep) may differ from the database clock by at most this many seconds; beyond it the call is refused (entitlement) or clamped (wallet). Tests widen it.'),
    ('billing_timezone', 'Asia/Kolkata',
        'The zone in which billing periods are computed (anchor + n x interval), independent of the session TimeZone. India, the billing jurisdiction.'),
    ('ent_late_apply_grace_hours', '24',
        'A paid period is anchored at the capture time when applied within this many hours; applied later (a backlog, a replay) it is anchored at the apply time, so lateness never costs the customer paid time.'),
    ('ent_billing_backoff_base_seconds', '300',
        'First retry delay for a postpaid entitlement whose invoicing failed; doubles with each failure.'),
    ('ent_billing_backoff_cap_seconds', '86400',
        'Upper bound of that retry delay (one day).'),
    ('ent_billing_catchup_max_periods', '12',
        'The most periods one billing run invoices for one entitlement that is behind.'),
    ('wallet_milli_per_credit', '1000',
        'Wallet v2 stores credit as milli-credits; this is the display unit, defined once: 1 credit = this many milli-credits.'),
    ('wallet_expiry_enforced', '0',
        'POLICY SWITCH (customer terms pending; CA/legal to confirm): 0 = purchased credit never expires; 1 = a top-up expires after its plan validity. Free grants with an explicit expiry always expire.')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    table_name := 'pay_config'; rows_inserted := v_n; RETURN NEXT;

    RETURN;
END;
$$;
