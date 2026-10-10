-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _wlt_grant_free (INTERNAL; bin/pay-wallet grant-free, or a platform's own authorised admin route)
--
-- Promotional credit, no money. INTERNAL because it mints credit. Idempotent per key (a replay returns the original; the same key with a different
-- amount or expiry is refused, PY071). p_expires_at is the caller's explicit choice and is honoured (the policy switch gates only pack-derived
-- top-up expiry); it must lie after the grant. granted_at = least(p_at, now()).
CREATE OR REPLACE FUNCTION _wlt_grant_free(p_tenant_id UUID, p_platform_code VARCHAR(50), p_key TEXT, p_milli BIGINT, p_at TIMESTAMPTZ,
                                           p_expires_at TIMESTAMPTZ, p_actor TEXT, p_reason TEXT)
RETURNS TABLE (o_outcome TEXT, o_grant_id BIGINT, o_wallet_id BIGINT) AS $$
DECLARE
    v_wallet BIGINT;
    v_key    TEXT := 'free:' || coalesce(p_key, '');
    v_hash   TEXT := encode(sha256(convert_to(concat_ws('|', 'free', p_milli, p_expires_at::text), 'UTF8')), 'hex');
    v_g      wlt_grants;
    v_at     TIMESTAMPTZ := least(p_at, now());
BEGIN
    IF p_key IS NULL OR btrim(p_key) = '' OR p_milli IS NULL OR p_milli <= 0 OR p_at IS NULL OR p_actor IS NULL OR btrim(p_actor) = '' OR p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION '_wlt_grant_free: key, a positive amount, time, actor and reason are required.' USING ERRCODE = 'PY070';
    END IF;
    IF p_expires_at IS NOT NULL AND p_expires_at <= v_at THEN
        RAISE EXCEPTION '_wlt_grant_free: the expiry (%) must be after the grant (%).', p_expires_at, v_at USING ERRCODE = 'PY070';
    END IF;
    v_wallet := _wlt_wallet_lock(p_tenant_id, p_platform_code);
    SELECT * INTO v_g FROM wlt_grants WHERE wallet_id = v_wallet AND grant_key = v_key;
    IF FOUND THEN
        IF v_g.request_hash <> v_hash THEN
            RAISE EXCEPTION 'grant key "%" was already used for a different grant.', p_key USING ERRCODE = 'PY071';
        END IF;
        o_outcome := 'already_applied'; o_grant_id := v_g.id; o_wallet_id := v_wallet;
        RETURN NEXT; RETURN;
    END IF;
    INSERT INTO wlt_grants (wallet_id, source, granted_milli, remaining_milli, grant_key, granted_at, expires_at, created_by, request_hash)
    VALUES (v_wallet, 'free_grant', p_milli, p_milli, v_key, v_at, p_expires_at, p_actor, v_hash) RETURNING * INTO v_g;
    PERFORM _ledger_post('free_grant', v_key, v_at, jsonb_build_array(
        jsonb_build_object('account', 'wallet:' || v_wallet, 'amount_milli', p_milli),
        jsonb_build_object('account', 'src:free_grant', 'amount_milli', -p_milli)));
    o_outcome := 'applied'; o_grant_id := v_g.id; o_wallet_id := v_wallet;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
