-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: pay_webhook_replay_candidates
--
-- The rows a replay should re-drive: failed and unattributed rows, plus 'received' rows older than
-- p_stale_after_seconds (processing was interrupted before it recorded an outcome), whose lease/backoff has expired.
-- Ordered FEWEST ATTEMPTS FIRST, then oldest: a row that keeps failing sinks behind fresh work instead of
-- starving it, and 'dead' rows are never listed. The replayer claims each id (pay_webhook_claim) before processing,
-- so listing is advisory and safe to run concurrently.
CREATE OR REPLACE FUNCTION pay_webhook_replay_candidates(
    p_limit               INTEGER DEFAULT 50,
    p_stale_after_seconds INTEGER DEFAULT 300
) RETURNS TABLE (o_id BIGINT, o_gateway_code TEXT, o_event_id TEXT, o_status TEXT, o_attempts INTEGER, o_received_at TIMESTAMPTZ) AS $$
    SELECT i.id, i.gateway_code, i.event_id, i.status, i.attempts, i.received_at
      FROM pay_webhook_inbox i
     WHERE (i.status IN ('failed', 'unattributed')
            OR (i.status = 'received' AND i.received_at < now() - make_interval(secs => p_stale_after_seconds)))
       AND (i.locked_until IS NULL OR i.locked_until < now())
     ORDER BY i.attempts, i.received_at, i.id
     LIMIT p_limit;
$$ LANGUAGE sql STABLE;
