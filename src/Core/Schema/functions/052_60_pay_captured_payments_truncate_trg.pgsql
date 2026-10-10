-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: BEFORE TRUNCATE guard on pay_captured_payments (pay_no_truncate, 035_24)
CREATE OR REPLACE TRIGGER pay_captured_payments_no_truncate
    BEFORE TRUNCATE ON pay_captured_payments
    FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
