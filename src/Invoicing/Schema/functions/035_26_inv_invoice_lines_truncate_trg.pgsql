-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: BEFORE TRUNCATE guard on inv_invoice_lines (pay_no_truncate, 035_24)
CREATE OR REPLACE TRIGGER inv_invoice_lines_no_truncate
    BEFORE TRUNCATE ON inv_invoice_lines
    FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
