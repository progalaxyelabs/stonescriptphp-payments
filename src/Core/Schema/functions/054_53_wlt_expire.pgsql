-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _wlt_expire_due, _wlt_expire_one (INTERNAL; bin/pay-wallet expire)
--
-- The expiry sweep, ONE WALLET PER TRANSACTION in small batches (so it never holds many wallet locks at once, and a drain waits for one wallet at most):
--   _wlt_expire_due(as_of, limit)   ids of wallets with unspent credit that has expired by as_of (read-only). A future as_of is clamped to now() + skew,
--                                   so a sweep dated in the future forfeits nothing early.
--   _wlt_expire_one(wallet, as_of)  forfeits that wallet's expired credit under its row lock; returns the milli forfeited.
CREATE OR REPLACE FUNCTION _wlt_expire_due(p_as_of TIMESTAMPTZ DEFAULT now(), p_limit INTEGER DEFAULT 100) RETURNS TABLE (o_wallet_id BIGINT) AS $$
    SELECT DISTINCT wallet_id FROM wlt_grants WHERE remaining_milli > 0 AND expires_at IS NOT NULL AND expires_at <= _pay_clamp_future(p_as_of) ORDER BY wallet_id LIMIT p_limit;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION _wlt_expire_one(p_wallet_id BIGINT, p_as_of TIMESTAMPTZ DEFAULT now()) RETURNS BIGINT AS $$
BEGIN
    PERFORM 1 FROM wlt_wallets WHERE id = p_wallet_id FOR UPDATE;
    RETURN _wlt_forfeit_expired(p_wallet_id, _pay_clamp_future(p_as_of));
END;
$$ LANGUAGE plpgsql;
