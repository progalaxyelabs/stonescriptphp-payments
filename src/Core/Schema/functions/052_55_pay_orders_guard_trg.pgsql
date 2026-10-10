-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: triggers pay_orders_guard / pay_events_guard (052_54)
CREATE OR REPLACE TRIGGER pay_orders_guard
    BEFORE UPDATE OR DELETE ON pay_orders
    FOR EACH ROW EXECUTE FUNCTION pay_orders_guard();
