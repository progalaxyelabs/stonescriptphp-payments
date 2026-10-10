-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _ent_invoice_paid (trigger function; INTERNAL)
--
-- When an invoice becomes paid (by ANY path: a webhook capture, an operator's mark-paid, inv_record_payment), the postpaid entitlement
-- it was billed to is restored IN THE SAME TRANSACTION: its snapshot status is recomputed from the facts (so another invoice that
-- is still overdue keeps it read-only) and an entitlement.changed event is appended when the status moved.
CREATE OR REPLACE FUNCTION _ent_invoice_paid() RETURNS TRIGGER AS $$
DECLARE
    v_ent ent_entitlements;
    v_eff RECORD;
    v_old TEXT;
BEGIN
    FOR v_ent IN
        SELECT e.* FROM ent_entitlements e JOIN ent_billing_runs r ON r.entitlement_id = e.id WHERE r.invoice_id = NEW.id FOR UPDATE OF e
    LOOP
        IF v_ent.status IN ('suspended', 'ended') THEN CONTINUE; END IF;
        SELECT * INTO v_eff FROM _ent_effective(v_ent, now());
        IF v_eff.o_status <> v_ent.status THEN
            v_old := v_ent.status;
            UPDATE ent_entitlements SET status = v_eff.o_status, updated_at = now(), updated_by = 'invoice-paid' WHERE id = v_ent.id RETURNING * INTO v_ent;
            PERFORM _ent_emit(v_ent, 'payment_restored', NULL, jsonb_build_object('from', v_old, 'invoice_id', NEW.id));
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
