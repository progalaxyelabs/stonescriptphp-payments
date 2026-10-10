-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: trigger inv_invoices_guard
--
-- Attaches inv_invoices_guard() (035_14). Kept in its own file after the function,
-- the same shape as the outbox trigger, so it sorts after the function and the
-- gateway redeploys it with the functions.
CREATE OR REPLACE TRIGGER inv_invoices_guard
    BEFORE INSERT OR UPDATE OR DELETE ON inv_invoices
    FOR EACH ROW EXECUTE FUNCTION inv_invoices_guard();
