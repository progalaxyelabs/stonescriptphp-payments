-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: BEFORE TRUNCATE guard on pay_events (pay_no_truncate, 035_24)
CREATE OR REPLACE TRIGGER pay_events_no_truncate
    BEFORE TRUNCATE ON pay_events
    FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
