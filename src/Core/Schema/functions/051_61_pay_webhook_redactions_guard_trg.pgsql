-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: trigger pay_webhook_redactions_guard (051_60)
CREATE OR REPLACE TRIGGER pay_webhook_redactions_guard
    BEFORE UPDATE OR DELETE ON pay_webhook_redactions
    FOR EACH ROW EXECUTE FUNCTION pay_webhook_redactions_guard();
