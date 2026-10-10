-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: BEFORE TRUNCATE guard on inv_invoices (pay_no_truncate, 035_24)
CREATE OR REPLACE TRIGGER inv_invoices_no_truncate
    BEFORE TRUNCATE ON inv_invoices
    FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
