-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _wlt_wallet_lock (INTERNAL)
-- Finds or creates the wallet and takes its row lock FOR UPDATE (held to the end of the transaction). Every wallet writer starts here.
CREATE OR REPLACE FUNCTION _wlt_wallet_lock(p_tenant UUID, p_platform VARCHAR(50), p_code TEXT DEFAULT 'default') RETURNS BIGINT AS $$
DECLARE
    v_id BIGINT;
BEGIN
    IF p_tenant IS NULL OR p_platform IS NULL OR btrim(p_platform) = '' THEN
        RAISE EXCEPTION 'wallet: tenant and platform are required.' USING ERRCODE = 'PY070';
    END IF;
    INSERT INTO wlt_wallets (tenant_id, platform_code, code) VALUES (p_tenant, p_platform, coalesce(p_code, 'default')) ON CONFLICT DO NOTHING;
    SELECT id INTO v_id FROM wlt_wallets WHERE tenant_id = p_tenant AND platform_code = p_platform AND code = coalesce(p_code, 'default') FOR UPDATE;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql;
