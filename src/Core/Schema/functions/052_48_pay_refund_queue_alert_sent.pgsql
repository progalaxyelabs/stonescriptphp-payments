-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: pay_refund_queue_alert_sent
-- Stamps an ageing alert as delivered (see pay_refund_queue_aged). Call it only after the alert sink succeeded.
CREATE OR REPLACE FUNCTION pay_refund_queue_alert_sent(p_id BIGINT) RETURNS VOID AS $$
    UPDATE pay_refund_queue SET last_alert_at = now() WHERE id = p_id AND status = 'open';
$$ LANGUAGE sql;
