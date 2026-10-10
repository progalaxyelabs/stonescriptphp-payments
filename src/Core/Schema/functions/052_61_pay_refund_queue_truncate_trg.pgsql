-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: BEFORE TRUNCATE guard on pay_refund_queue (pay_no_truncate, 035_24)
CREATE OR REPLACE TRIGGER pay_refund_queue_no_truncate
    BEFORE TRUNCATE ON pay_refund_queue
    FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
