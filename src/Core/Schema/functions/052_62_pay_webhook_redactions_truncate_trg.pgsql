-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: BEFORE TRUNCATE guard on pay_webhook_redactions (pay_no_truncate, 035_24)
CREATE OR REPLACE TRIGGER pay_webhook_redactions_no_truncate
    BEFORE TRUNCATE ON pay_webhook_redactions
    FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
