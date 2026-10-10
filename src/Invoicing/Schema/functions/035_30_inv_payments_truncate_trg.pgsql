-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: BEFORE TRUNCATE guard on inv_payments (pay_no_truncate, 035_24)
CREATE OR REPLACE TRIGGER inv_payments_no_truncate
    BEFORE TRUNCATE ON inv_payments
    FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
