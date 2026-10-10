-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _wlt_topup (INTERNAL; called only by pay_apply_capture)
--
-- Credits a wallet for a PACK purchase, BOUND TO A CAPTURE: the captured payment must exist (PY070) and the grant key is
-- 'cap:<gateway>:<txn>', so replaying the capture credits exactly once (the same key with a different pack or amount is refused, PY071).
-- Internal on purpose: nothing but a captured payment may mint paid credit.
--   credits  = the PACK's explicit credits_milli. There is NO division at capture time: the amount paid does not decide the credits, so a
--              GST-inclusive or discounted price cannot make a paid top-up unfulfillable.
--   granted_at = least(capture time, now()): a capture dated in the future cannot make credit appear before it exists.
--   expiry   = granted_at + the pack's validity, ONLY when pay_config 'wallet_expiry_enforced' = 1; with the default 0 credit never expires,
--              whatever the pack says (expiry is a policy switch that waits for the customer terms, then a data change).
-- Refusals (ER013 pack grants nothing, ER015 pack not sellable, PY070 no capture, PY071 key reused) are mapped by pay_apply_capture to a
-- refund-queue entry 'wallet_unfulfillable': a paid top-up is never lost silently.
CREATE OR REPLACE FUNCTION _wlt_topup(p_tenant UUID, p_platform VARCHAR(50), p_pack_id BIGINT, p_amount BIGINT, p_gateway TEXT, p_txn TEXT, p_at TIMESTAMPTZ, p_actor TEXT)
RETURNS TABLE (o_grant_id BIGINT, o_wallet_id BIGINT, o_granted_milli BIGINT, o_expires_at TIMESTAMPTZ, o_already BOOLEAN) AS $$
DECLARE
    v_wallet BIGINT;
    v_pack   RECORD;
    v_key    TEXT := 'cap:' || p_gateway || ':' || p_txn;
    v_hash   TEXT := encode(sha256(convert_to(concat_ws('|', 'topup', p_pack_id, p_amount, p_gateway, p_txn), 'UTF8')), 'hex');
    v_g      wlt_grants;
    v_at     TIMESTAMPTZ := least(p_at, now());
    v_expires TIMESTAMPTZ;
BEGIN
    IF p_gateway IS NULL OR p_txn IS NULL OR p_amount IS NULL OR p_amount < 0 OR p_at IS NULL THEN
        RAISE EXCEPTION '_wlt_topup: gateway, transaction, time and a non-negative amount are required.' USING ERRCODE = 'PY070';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pay_captured_payments WHERE gateway_code = p_gateway AND gateway_txn_ref = p_txn AND status = 'success') THEN
        RAISE EXCEPTION 'no successful captured payment %/% exists: paid credit is only minted for a capture.', p_gateway, p_txn USING ERRCODE = 'PY070';
    END IF;
    v_wallet := _wlt_wallet_lock(p_tenant, p_platform);
    SELECT * INTO v_g FROM wlt_grants WHERE wallet_id = v_wallet AND grant_key = v_key;
    IF FOUND THEN
        IF v_g.request_hash <> v_hash THEN
            RAISE EXCEPTION 'top-up key "%" was already used for a different request.', v_key USING ERRCODE = 'PY071';
        END IF;
        o_grant_id := v_g.id; o_wallet_id := v_wallet; o_granted_milli := v_g.granted_milli; o_expires_at := v_g.expires_at; o_already := TRUE;
        RETURN NEXT; RETURN;
    END IF;

    SELECT wp.id, wp.credits_milli, wp.validity_duration, wp.validity_uom INTO v_pack
      FROM wlt_packs wp JOIN pricing_plans pp ON pp.id = wp.pricing_plan_id WHERE wp.id = p_pack_id AND wp.is_active AND pp.is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'wallet pack % is not currently sellable (inactive or does not exist)', p_pack_id USING ERRCODE = 'ER015';
    END IF;
    IF v_pack.credits_milli <= 0 THEN
        RAISE EXCEPTION 'wallet pack % grants no credit', p_pack_id USING ERRCODE = 'ER013';
    END IF;
    v_expires := CASE WHEN _pay_config_int('wallet_expiry_enforced') = 1 AND v_pack.validity_duration IS NOT NULL
                      THEN v_at + (v_pack.validity_duration || ' ' || v_pack.validity_uom)::interval END;

    INSERT INTO wlt_grants (wallet_id, source, granted_milli, remaining_milli, amount_paid, grant_key, gateway_code, gateway_txn_ref,
                            granted_at, expires_at, created_by, request_hash)
    VALUES (v_wallet, 'topup', v_pack.credits_milli, v_pack.credits_milli, p_amount, v_key, p_gateway, p_txn, v_at, v_expires, p_actor, v_hash)
    RETURNING * INTO v_g;
    PERFORM _ledger_post('topup', v_key, v_at, jsonb_build_array(
        jsonb_build_object('account', 'wallet:' || v_wallet, 'amount_milli', v_pack.credits_milli),
        jsonb_build_object('account', 'src:topup', 'amount_milli', -v_pack.credits_milli)));
    o_grant_id := v_g.id; o_wallet_id := v_wallet; o_granted_milli := v_pack.credits_milli; o_expires_at := v_expires; o_already := FALSE;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
