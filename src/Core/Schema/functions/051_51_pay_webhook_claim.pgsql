-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: pay_webhook_claim
--
-- Takes a short processing lease on one inbox row and returns it, or returns NO ROW when
-- the row is not claimable: already applied/ignored/foreign, or leased by another worker.
-- This is what makes two simultaneous deliveries of one event, or a delivery racing a
-- replay, process it only once. The lease is released by pay_webhook_mark; if the worker
-- dies the lease simply expires and the row becomes claimable again.
--
-- Claimable: received, failed, unattributed. attempts counts claims. The normalised event is
-- returned as JSON text (NULL when the stored body was unreadable).
CREATE OR REPLACE FUNCTION pay_webhook_claim(p_id BIGINT, p_lease_seconds INTEGER DEFAULT 120)
RETURNS TABLE (
    o_id BIGINT, o_gateway_code TEXT, o_event_id TEXT, o_event_type TEXT, o_status TEXT,
    o_attempts INTEGER, o_raw_body TEXT, o_event TEXT
) AS $$
    UPDATE pay_webhook_inbox i
       SET attempts = i.attempts + 1,
           locked_until = now() + make_interval(secs => p_lease_seconds),
           updated_at = now()
     WHERE i.id = p_id
       AND i.status IN ('received', 'failed', 'unattributed')
       AND (i.locked_until IS NULL OR i.locked_until < now())
    RETURNING i.id, i.gateway_code, i.event_id, i.event_type, i.status, i.attempts, i.raw_body, i.event::text;
$$ LANGUAGE sql;
