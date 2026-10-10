-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: BEFORE TRUNCATE guard on pay_orders (pay_no_truncate, 035_24)
CREATE OR REPLACE TRIGGER pay_orders_no_truncate
    BEFORE TRUNCATE ON pay_orders
    FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
