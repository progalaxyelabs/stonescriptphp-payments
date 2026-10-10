-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: BEFORE TRUNCATE guard on pay_webhook_inbox (pay_no_truncate, 035_24)
CREATE OR REPLACE TRIGGER pay_webhook_inbox_no_truncate
    BEFORE TRUNCATE ON pay_webhook_inbox
    FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
