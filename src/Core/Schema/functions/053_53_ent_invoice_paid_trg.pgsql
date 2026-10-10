-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: trigger on inv_invoices -> _ent_invoice_paid (053_52)
CREATE OR REPLACE TRIGGER ent_invoice_paid
    AFTER UPDATE OF status ON inv_invoices
    FOR EACH ROW WHEN (NEW.status = 'paid' AND OLD.status IS DISTINCT FROM 'paid')
    EXECUTE FUNCTION _ent_invoice_paid();
