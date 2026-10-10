-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: trigger pay_events_guard (052_54)
CREATE OR REPLACE TRIGGER pay_events_guard
    BEFORE UPDATE OR DELETE ON pay_events
    FOR EACH ROW EXECUTE FUNCTION pay_orders_guard();
