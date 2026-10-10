-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: inv_invoice_lines_guard
--
-- The lines of an invoice that has left draft are as immutable as the header (PY019):
--   UPDATE / DELETE   refused when the invoice is past draft
--   re-pointing       a line's invoice_id never changes
--   INSERT            refused on a non-draft invoice, EXCEPT inside inv_issue_invoice (it flags its own
--                     transaction with pay.issuing and inserts the lines right after the header it just
--                     wrote): without that, a line could be added to an issued invoice
-- The lines of a DRAFT stay writable (so a draft and its lines can be deleted).
CREATE OR REPLACE FUNCTION inv_invoice_lines_guard() RETURNS TRIGGER AS $$
DECLARE
    v_status TEXT;
BEGIN
    PERFORM _inv_assert_schema_current();
    IF TG_OP = 'UPDATE' AND NEW.invoice_id IS DISTINCT FROM OLD.invoice_id THEN
        RAISE EXCEPTION 'line %: a line cannot be moved to another invoice.', OLD.id USING ERRCODE = 'PY019';
    END IF;
    IF TG_OP = 'INSERT' THEN
        SELECT i.status INTO v_status FROM inv_invoices i WHERE i.id = NEW.invoice_id;
        IF FOUND AND v_status <> 'draft' AND coalesce(current_setting('pay.issuing', true), '') <> 'on' THEN
            RAISE EXCEPTION 'invoice % is % and no line can be added to it.', NEW.invoice_id, v_status USING ERRCODE = 'PY019';
        END IF;
        RETURN NEW;
    END IF;
    SELECT i.status INTO v_status FROM inv_invoices i WHERE i.id = OLD.invoice_id;
    IF FOUND AND v_status <> 'draft' THEN
        RAISE EXCEPTION 'line % belongs to an invoice that is % and cannot be % - its lines are frozen with it.',
            OLD.id, v_status, lower(TG_OP) USING ERRCODE = 'PY019';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
