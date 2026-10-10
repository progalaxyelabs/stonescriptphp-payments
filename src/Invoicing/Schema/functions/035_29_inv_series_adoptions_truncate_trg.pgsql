-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: BEFORE TRUNCATE guard on inv_series_adoptions (pay_no_truncate, 035_24)
CREATE OR REPLACE TRIGGER inv_series_adoptions_no_truncate
    BEFORE TRUNCATE ON inv_series_adoptions
    FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
