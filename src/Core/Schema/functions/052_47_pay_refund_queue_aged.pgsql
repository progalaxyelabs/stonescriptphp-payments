-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: pay_refund_queue_aged / pay_refund_queue_alert_sent
--
-- The ageing alert for the refund queue: open entries older than pay_config 'refund_queue_alert_after_days' (default 3) that have not
-- been alerted in the last 'refund_queue_alert_repeat_hours' (default 24). A job (RefundQueueMonitor, bin/pay-refund-queue-alerts)
-- raises one alert per row returned and then calls pay_refund_queue_alert_sent() ONLY after the sink succeeded, so an entry is
-- re-alerted every repeat period until a human closes it with _pay_refund_queue_resolve(). Read-only apart from the stamp.
CREATE OR REPLACE FUNCTION pay_refund_queue_aged(p_limit INTEGER DEFAULT 100)
RETURNS TABLE (o_id BIGINT, o_gateway_code TEXT, o_gateway_txn_ref TEXT, o_order_ref TEXT, o_amount_minor BIGINT, o_currency TEXT,
               o_reason TEXT, o_age_days INTEGER) AS $$
    SELECT q.id, q.gateway_code, q.gateway_txn_ref, q.order_ref, q.amount_minor, q.currency, q.reason,
           (extract(epoch FROM (now() - q.created_at)) / 86400)::int
      FROM pay_refund_queue q
     WHERE q.status = 'open'
       AND q.created_at < now() - make_interval(days => _pay_config_int('refund_queue_alert_after_days')::int)
       AND (q.last_alert_at IS NULL OR q.last_alert_at < now() - make_interval(hours => _pay_config_int('refund_queue_alert_repeat_hours')::int))
     ORDER BY q.created_at, q.id
     LIMIT p_limit;
$$ LANGUAGE sql STABLE;
