-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: wallet_balance, wallet_forfeited (PUBLIC, read-only)
--
-- wallet_balance: the SPENDABLE balance at a moment (credit granted by then and not expired by then), in milli-credits and in credits, plus when the next
-- credit expires.
CREATE OR REPLACE FUNCTION wallet_balance(p_tenant_id UUID, p_platform_code VARCHAR(50), p_as_of TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (o_milli BIGINT, o_credits NUMERIC, o_next_expiry_at TIMESTAMPTZ, o_next_expiry_milli BIGINT) AS $$
    WITH w AS (SELECT id FROM wlt_wallets WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code AND code = 'default'),
         g AS (SELECT gr.* FROM wlt_grants gr JOIN w ON w.id = gr.wallet_id
                WHERE gr.remaining_milli > 0 AND gr.granted_at <= p_as_of AND (gr.expires_at IS NULL OR gr.expires_at > p_as_of)),
         n AS (SELECT min(expires_at) AS at FROM g WHERE expires_at IS NOT NULL)
    SELECT coalesce((SELECT sum(remaining_milli) FROM g), 0)::bigint,
           coalesce((SELECT sum(remaining_milli) FROM g), 0)::numeric / _pay_config_int('wallet_milli_per_credit'),
           (SELECT at FROM n),
           (SELECT sum(remaining_milli) FROM g WHERE expires_at = (SELECT at FROM n))::bigint;
$$ LANGUAGE sql STABLE;

-- wallet_forfeited: credit that expired unspent (reported, never deleted). Settled by the sweep or lazily by the next drain.
CREATE OR REPLACE FUNCTION wallet_forfeited(p_tenant_id UUID, p_platform_code VARCHAR(50))
RETURNS TABLE (o_grant_id BIGINT, o_milli BIGINT, o_expired_at TIMESTAMPTZ, o_swept_at TIMESTAMPTZ) AS $$
    SELECT f.grant_id, f.milli, f.expired_at, f.swept_at FROM wlt_forfeits f JOIN wlt_wallets w ON w.id = f.wallet_id
     WHERE w.tenant_id = p_tenant_id AND w.platform_code = p_platform_code ORDER BY f.expired_at, f.id;
$$ LANGUAGE sql STABLE;
