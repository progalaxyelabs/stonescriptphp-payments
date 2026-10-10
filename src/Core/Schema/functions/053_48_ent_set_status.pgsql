-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _ent_set_status (INTERNAL; bin/pay-entitlement or the platform's own authorised admin route)
--
-- An operator suspends, ends or reinstates an entitlement. 'active' reinstates (access then follows the period / invoices again).
-- Audited, idempotent per key (the same key with a different request is refused, PY062).
CREATE OR REPLACE FUNCTION _ent_set_status(p_tenant_id UUID, p_platform_code VARCHAR(50), p_product TEXT, p_status TEXT, p_key TEXT, p_actor TEXT, p_reason TEXT,
                                          p_at TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (o_outcome TEXT, o_status TEXT) AS $$
DECLARE
    v_product TEXT := coalesce(p_product, 'default');
    v_hash    TEXT := encode(sha256(convert_to(concat_ws('|', 'status', coalesce(p_product, 'default'), p_status), 'UTF8')), 'hex');
    v_act     ent_activations;
    v_ent     ent_entitlements;
BEGIN
    PERFORM _pay_bound_clock(p_at, 'status change time');
    IF p_status IS NULL OR p_status NOT IN ('suspended', 'ended', 'active') OR p_key IS NULL OR btrim(p_key) = ''
       OR p_actor IS NULL OR btrim(p_actor) = '' OR p_reason IS NULL OR btrim(p_reason) = '' OR p_tenant_id IS NULL OR p_platform_code IS NULL OR p_at IS NULL THEN
        RAISE EXCEPTION '_ent_set_status: tenant, platform, status (suspended|ended|active), key, actor and reason are required.' USING ERRCODE = 'PY060';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('ent:' || p_tenant_id::text || ':' || p_platform_code || ':' || v_product, 0));
    SELECT * INTO v_act FROM ent_activations WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code AND idempotency_key = p_key;
    IF FOUND THEN
        IF v_act.request_hash <> v_hash THEN
            RAISE EXCEPTION 'idempotency key "%" was already used for a different entitlement request.', p_key USING ERRCODE = 'PY062';
        END IF;
        SELECT * INTO v_ent FROM ent_entitlements WHERE id = v_act.entitlement_id;
        o_outcome := 'already_applied'; o_status := v_ent.status;
        RETURN NEXT; RETURN;
    END IF;
    SELECT * INTO v_ent FROM ent_entitlements WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code AND product = v_product FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'tenant has no entitlement for product "%".', v_product USING ERRCODE = 'PY061';
    END IF;
    UPDATE ent_entitlements SET status = p_status, updated_at = greatest(p_at, updated_at), updated_by = p_actor WHERE id = v_ent.id RETURNING * INTO v_ent;
    INSERT INTO ent_activations (entitlement_id, tenant_id, platform_code, product, kind, plan_ref, idempotency_key, request_hash, actor, reason, created_at)
    VALUES (v_ent.id, p_tenant_id, p_platform_code, v_product, 'status', v_ent.plan_ref, p_key, v_hash, p_actor, p_reason, p_at);
    PERFORM _ent_emit(v_ent, 'status', NULL, jsonb_build_object('actor', p_actor, 'reason', p_reason));
    o_outcome := 'applied'; o_status := v_ent.status;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
