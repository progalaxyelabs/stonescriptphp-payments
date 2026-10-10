-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: trigger inv_invoice_lines_guard
CREATE OR REPLACE TRIGGER inv_invoice_lines_guard
    BEFORE INSERT OR UPDATE OR DELETE ON inv_invoice_lines
    FOR EACH ROW EXECUTE FUNCTION inv_invoice_lines_guard();
