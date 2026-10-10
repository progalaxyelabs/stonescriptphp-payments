-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: inv_invoices_guard
--
-- Row guard on inv_invoices (BEFORE INSERT OR UPDATE OR DELETE). It makes a statutory document
-- immutable once it leaves draft, and keeps TEST and live numbers structurally apart. Violations
-- are PY019 (409) unless noted.
--
--   schema     refuses (PY040) when the upgrade migration has not been applied, naming it
--   DELETE     refused for any invoice that is not a draft
--   status     only the legal edges of inv_invoice_status_transitions: an issued invoice can never be
--              set back to draft (which would make it deletable and its number reusable)
--   number     never changes once set; set exactly once, on the draft -> issued edge
--   frozen     once past draft: the document and money columns (type, treatment, place of supply,
--              every amount, currency, FX, billing country/state, owner, charge source/ref, period,
--              SAC) never change. The numbering and snapshot columns never change either, EXCEPT
--              that a LEGACY row (series_id NULL: issued before those columns existed) may have a
--              NULL snapshot column back-filled once. A row issued from a series is never back-filled.
--   status, due_date, paid_at / voided_at / cancelled_at stay writable: that is the lifecycle
--   mode      a row's mode must agree with its number: test <=> TEST-prefixed. A NULL mode means a legacy
--             LIVE row. Checked on INSERT and whenever mode or number change, so an old TEST-numbered
--             legacy row keeps working (and is back-filled 'test' by _pay_apply_schema_upgrades).
--             A row tied to a series carries that series' mode and a number starting with its head.
CREATE OR REPLACE FUNCTION inv_invoices_guard() RETURNS TRIGGER AS $$
DECLARE
    v_series inv_series;
    v_mode   TEXT;
BEGIN
    PERFORM _inv_assert_schema_current();

    IF TG_OP = 'DELETE' THEN
        IF OLD.status <> 'draft' THEN
            RAISE EXCEPTION 'invoice % (%) is % and cannot be deleted: void or cancel it; its number stays in the books.',
                OLD.id, OLD.invoice_number, OLD.status USING ERRCODE = 'PY019';
        END IF;
        RETURN OLD;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF NEW.status IS DISTINCT FROM OLD.status AND NOT EXISTS (
               SELECT 1 FROM inv_invoice_status_transitions t WHERE t.from_status = OLD.status AND t.to_status = NEW.status) THEN
            RAISE EXCEPTION 'invoice %: status % -> % is not a legal transition.', OLD.id, OLD.status, NEW.status
                USING ERRCODE = 'PY019';
        END IF;

        IF OLD.invoice_number IS NOT NULL AND NEW.invoice_number IS DISTINCT FROM OLD.invoice_number THEN
            RAISE EXCEPTION 'invoice_number of invoice % is immutable ("%").', OLD.id, OLD.invoice_number
                USING ERRCODE = 'PY019';
        END IF;
        IF OLD.invoice_number IS NULL AND NEW.invoice_number IS NOT NULL
           AND NOT (OLD.status = 'draft' AND NEW.status = 'issued') THEN
            RAISE EXCEPTION 'invoice % may receive its number only on the draft -> issued edge.', OLD.id
                USING ERRCODE = 'PY019';
        END IF;

        IF OLD.status <> 'draft' THEN
            -- numbering identity: never changes past draft, legacy or not
            IF NEW.series_id IS DISTINCT FROM OLD.series_id OR NEW.fy_label IS DISTINCT FROM OLD.fy_label
               OR NEW.number_seq IS DISTINCT FROM OLD.number_seq THEN
                RAISE EXCEPTION 'invoice %: its series, financial year and serial are frozen once it is issued.', OLD.id
                    USING ERRCODE = 'PY019';
            END IF;
            -- snapshots: a changed value is refused unless it fills a NULL on a LEGACY row
            IF (NEW.issuer_id IS DISTINCT FROM OLD.issuer_id AND (OLD.issuer_id IS NOT NULL OR OLD.series_id IS NOT NULL))
               OR (NEW.mode IS DISTINCT FROM OLD.mode AND (OLD.mode IS NOT NULL OR OLD.series_id IS NOT NULL))
               OR (NEW.issue_date IS DISTINCT FROM OLD.issue_date AND (OLD.issue_date IS NOT NULL OR OLD.series_id IS NOT NULL))
               OR (NEW.seller_legal_name IS DISTINCT FROM OLD.seller_legal_name AND (OLD.seller_legal_name IS NOT NULL OR OLD.series_id IS NOT NULL))
               OR (NEW.seller_gstin IS DISTINCT FROM OLD.seller_gstin AND (OLD.seller_gstin IS NOT NULL OR OLD.series_id IS NOT NULL))
               OR (NEW.seller_registration_status IS DISTINCT FROM OLD.seller_registration_status AND (OLD.seller_registration_status IS NOT NULL OR OLD.series_id IS NOT NULL))
               OR (NEW.seller_state_code IS DISTINCT FROM OLD.seller_state_code AND (OLD.seller_state_code IS NOT NULL OR OLD.series_id IS NOT NULL))
               OR (NEW.seller_address IS DISTINCT FROM OLD.seller_address AND (OLD.seller_address IS NOT NULL OR OLD.series_id IS NOT NULL))
               OR (NEW.buyer_legal_name IS DISTINCT FROM OLD.buyer_legal_name AND (OLD.buyer_legal_name IS NOT NULL OR OLD.series_id IS NOT NULL))
               OR (NEW.buyer_gstin IS DISTINCT FROM OLD.buyer_gstin AND (OLD.buyer_gstin IS NOT NULL OR OLD.series_id IS NOT NULL))
               OR (NEW.buyer_registration_status IS DISTINCT FROM OLD.buyer_registration_status AND (OLD.buyer_registration_status IS NOT NULL OR OLD.series_id IS NOT NULL))
               OR (NEW.buyer_state_code IS DISTINCT FROM OLD.buyer_state_code AND (OLD.buyer_state_code IS NOT NULL OR OLD.series_id IS NOT NULL)) THEN
                RAISE EXCEPTION 'invoice %: numbering and snapshot columns are frozen once issued (only a NULL on a pre-existing legacy row may be back-filled).', OLD.id
                    USING ERRCODE = 'PY019';
            END IF;

            IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
               OR NEW.platform_code IS DISTINCT FROM OLD.platform_code
               OR NEW.charge_source IS DISTINCT FROM OLD.charge_source
               OR NEW.charge_ref IS DISTINCT FROM OLD.charge_ref
               OR NEW.period_start IS DISTINCT FROM OLD.period_start
               OR NEW.period_end IS DISTINCT FROM OLD.period_end
               OR NEW.document_type IS DISTINCT FROM OLD.document_type
               OR NEW.tax_treatment IS DISTINCT FROM OLD.tax_treatment
               OR NEW.place_of_supply_code IS DISTINCT FROM OLD.place_of_supply_code
               OR NEW.hsn_sac IS DISTINCT FROM OLD.hsn_sac
               OR NEW.taxable_value_minor IS DISTINCT FROM OLD.taxable_value_minor
               OR NEW.cgst_minor IS DISTINCT FROM OLD.cgst_minor
               OR NEW.sgst_minor IS DISTINCT FROM OLD.sgst_minor
               OR NEW.igst_minor IS DISTINCT FROM OLD.igst_minor
               OR NEW.round_off_minor IS DISTINCT FROM OLD.round_off_minor
               OR NEW.gross_total_minor IS DISTINCT FROM OLD.gross_total_minor
               OR NEW.currency IS DISTINCT FROM OLD.currency
               OR NEW.fx_rate IS DISTINCT FROM OLD.fx_rate
               OR NEW.amount_inr_minor IS DISTINCT FROM OLD.amount_inr_minor
               OR NEW.billing_country_code IS DISTINCT FROM OLD.billing_country_code
               OR NEW.billing_state_snapshot IS DISTINCT FROM OLD.billing_state_snapshot THEN
                RAISE EXCEPTION 'invoice % (%) is % and its document and money columns are frozen: void it and issue a corrected one (or a credit note).',
                    OLD.id, OLD.invoice_number, OLD.status USING ERRCODE = 'PY019';
            END IF;
        END IF;
    END IF;

    -- TEST / live agree with the number. NULL mode = a legacy LIVE row.
    IF NEW.invoice_number IS NOT NULL
       AND (TG_OP = 'INSERT' OR NEW.mode IS DISTINCT FROM OLD.mode OR NEW.invoice_number IS DISTINCT FROM OLD.invoice_number) THEN
        v_mode := coalesce(NEW.mode, 'live');
        IF (v_mode = 'test') IS DISTINCT FROM (upper(left(NEW.invoice_number, 4)) = 'TEST') THEN
            RAISE EXCEPTION 'invoice "%" is in % mode but its number % a TEST number: test and live numbers never mix.',
                NEW.invoice_number, v_mode, CASE WHEN v_mode = 'test' THEN 'is not' ELSE 'is' END
                USING ERRCODE = 'PY012';
        END IF;
    END IF;
    IF NEW.series_id IS NOT NULL THEN
        SELECT * INTO v_series FROM inv_series WHERE id = NEW.series_id;
        IF NEW.mode IS DISTINCT FROM v_series.mode THEN
            RAISE EXCEPTION 'invoice is tied to % series "%" but states mode %.', v_series.mode, v_series.series_code, NEW.mode
                USING ERRCODE = 'PY012';
        END IF;
        IF NEW.invoice_number IS NOT NULL
           AND left(NEW.invoice_number, length(_inv_series_head(v_series.prefix, v_series.sep))) <> _inv_series_head(v_series.prefix, v_series.sep) THEN
            RAISE EXCEPTION 'invoice number "%" does not belong to series "%".', NEW.invoice_number, v_series.series_code
                USING ERRCODE = 'PY019';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
