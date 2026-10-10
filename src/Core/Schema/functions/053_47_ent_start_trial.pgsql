-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: ent_start_trial (PUBLIC)
--
-- Starts the one free trial: records it in the pricing history (start_free_trial, which refuses a second trial, ER005) and creates the
-- 'trial' entitlement for the trial plan's duration, in one transaction. Idempotent per key. p_at must be within the clock skew of the database clock (PY064). Refused (PY061) when the tenant already
-- has an entitlement for the product.
CREATE OR REPLACE FUNCTION ent_start_trial(p_tenant_id UUID, p_platform_code VARCHAR(50), p_product TEXT, p_at TIMESTAMPTZ, p_key TEXT, p_actor TEXT)
RETURNS TABLE (o_outcome TEXT, o_activation_id BIGINT, o_period_end TIMESTAMPTZ) AS $$
DECLARE
    v_product TEXT := coalesce(p_product, 'default');
    v_hash    TEXT := encode(sha256(convert_to(concat_ws('|', 'trial', coalesce(p_product, 'default')), 'UTF8')), 'hex');
    v_cpp     customer_pricing_plans;
    v_dur     INTERVAL;
    v_r       RECORD;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR btrim(p_platform_code) = '' OR p_key IS NULL OR btrim(p_key) = ''
       OR p_actor IS NULL OR btrim(p_actor) = '' OR p_at IS NULL THEN
        RAISE EXCEPTION 'ent_start_trial: tenant, platform, time, idempotency key and actor are required.' USING ERRCODE = 'PY060';
    END IF;
    PERFORM _pay_bound_clock(p_at, 'trial start time');
    PERFORM pg_advisory_xact_lock(hashtextextended('ent:' || p_tenant_id::text || ':' || p_platform_code || ':' || v_product, 0));
    SELECT * INTO v_r FROM ent_activations WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code AND idempotency_key = p_key;
    IF FOUND THEN
        IF v_r.request_hash <> v_hash THEN
            RAISE EXCEPTION 'idempotency key "%" was already used for a different entitlement request.', p_key USING ERRCODE = 'PY062';
        END IF;
        o_outcome := 'already_applied'; o_activation_id := v_r.id; o_period_end := v_r.period_to;
        RETURN NEXT; RETURN;
    END IF;
    IF EXISTS (SELECT 1 FROM ent_entitlements WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code AND product = v_product) THEN
        RAISE EXCEPTION 'tenant already has an entitlement for product "%": a trial cannot be started.', v_product USING ERRCODE = 'PY061';
    END IF;
    v_cpp := start_free_trial(p_tenant_id, p_platform_code, p_at, p_actor);
    SELECT (spp.duration || ' ' || spp.duration_uom)::interval INTO v_dur FROM subscription_pricing_plans spp WHERE spp.id = v_cpp.subscription_pricing_plan_id;
    SELECT * INTO v_r FROM _ent_apply_period(p_tenant_id, p_platform_code, v_product, 'trial', 'trial', v_cpp.subscription_pricing_plan_id, v_dur,
        'trial', 'trial', p_at, p_key, v_hash, p_actor, 'free trial', NULL, NULL);
    o_outcome := 'applied'; o_activation_id := v_r.o_activation_id; o_period_end := v_r.o_period_to;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
