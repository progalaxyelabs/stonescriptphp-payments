-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: trigger pay_webhook_inbox_guard (051_54)
CREATE OR REPLACE TRIGGER pay_webhook_inbox_guard
    BEFORE UPDATE OR DELETE ON pay_webhook_inbox
    FOR EACH ROW EXECUTE FUNCTION pay_webhook_inbox_guard();
