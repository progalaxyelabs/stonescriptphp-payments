-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _ent_enroll_postpaid (INTERNAL; bin/pay-entitlement or the platform's own authorised admin route)
--
-- Puts a tenant on a POSTPAID plan: one invoice per period in arrears (ent_billing_run), access follows the invoices (unpaid past
-- the grace goes read-only; paying restores it). p_profile carries what every invoice needs:
--   series_code, mode ('live'|'test'), buyer {legal_name, registration_status, address_state, gstin?}, billing_country_code, billing_state,
--   hsn_sac, gst_rate (0.18), and optionally supply_type, document_type, round_off, due_days (default 0).
-- The plan must be an active postpaid subscription plan. Idempotent per key; a tenant that already has an entitlement for the product is
-- refused (PY061). The first invoice falls due at p_anchor + one plan period (computed in the billing zone, pay_config 'billing_timezone').
-- p_anchor may be in the past (a migration; the run then catches up, bounded) but not in the future beyond the clock skew (PY064).
CREATE OR REPLACE FUNCTION _ent_enroll_postpaid(p_tenant_id UUID, p_platform_code VARCHAR(50), p_product TEXT, p_subscription_pricing_plan_id BIGINT,
                                               p_profile JSONB, p_anchor TIMESTAMPTZ, p_key TEXT, p_actor TEXT)
RETURNS TABLE (o_outcome TEXT, o_entitlement_id BIGINT, o_next_billing_at TIMESTAMPTZ) AS $$
DECLARE
    v_product TEXT := coalesce(p_product, 'default');
    v_hash    TEXT;
    v_dur     INTERVAL;
    v_act     ent_activations;
    v_spp     RECORD;
    v_ent     ent_entitlements;
    v_series  inv_series;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR btrim(p_platform_code) = '' OR p_subscription_pricing_plan_id IS NULL OR p_profile IS NULL
       OR p_anchor IS NULL OR p_key IS NULL OR btrim(p_key) = '' OR p_actor IS NULL OR btrim(p_actor) = '' THEN
        RAISE EXCEPTION '_ent_enroll_postpaid: tenant, platform, plan, profile, anchor, key and actor are required.' USING ERRCODE = 'PY060';
    END IF;
    IF p_anchor IS NOT NULL AND p_anchor > now() + make_interval(secs => _pay_config_int('pay_clock_skew_seconds')) THEN
        RAISE EXCEPTION 'billing anchor (%) is in the future beyond the clock skew.', p_anchor USING ERRCODE = 'PY064';
    END IF;
    v_hash := encode(sha256(convert_to(concat_ws('|', 'enroll', v_product, p_subscription_pricing_plan_id::text, p_profile::text), 'UTF8')), 'hex');
    PERFORM pg_advisory_xact_lock(hashtextextended('ent:' || p_tenant_id::text || ':' || p_platform_code || ':' || v_product, 0));
    SELECT * INTO v_act FROM ent_activations WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code AND idempotency_key = p_key;
    IF FOUND THEN
        IF v_act.request_hash <> v_hash THEN
            RAISE EXCEPTION 'idempotency key "%" was already used for a different entitlement request.', p_key USING ERRCODE = 'PY062';
        END IF;
        SELECT * INTO v_ent FROM ent_entitlements WHERE id = v_act.entitlement_id;
        o_outcome := 'already_applied'; o_entitlement_id := v_ent.id; o_next_billing_at := v_ent.next_billing_at;
        RETURN NEXT; RETURN;
    END IF;
    IF EXISTS (SELECT 1 FROM ent_entitlements WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code AND product = v_product) THEN
        RAISE EXCEPTION 'tenant already has an entitlement for product "%".', v_product USING ERRCODE = 'PY061';
    END IF;
    SELECT spp.id, spp.pricing_plan_id, spp.duration, spp.duration_uom INTO v_spp
      FROM subscription_pricing_plans spp JOIN pricing_plans pp ON pp.id = spp.pricing_plan_id
     WHERE spp.id = p_subscription_pricing_plan_id AND spp.is_active AND pp.is_active AND NOT pp.is_trial AND spp.is_post_paid;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'plan % is not an active postpaid subscription plan.', p_subscription_pricing_plan_id USING ERRCODE = 'PY060';
    END IF;
    IF p_profile->>'series_code' IS NULL OR coalesce(p_profile->>'mode', '') NOT IN ('live', 'test') OR p_profile->'buyer' IS NULL
       OR p_profile->>'billing_country_code' IS NULL OR p_profile->>'billing_state' IS NULL OR p_profile->>'hsn_sac' IS NULL OR p_profile->>'gst_rate' IS NULL THEN
        RAISE EXCEPTION 'billing profile needs series_code, mode, buyer, billing_country_code, billing_state, hsn_sac and gst_rate.' USING ERRCODE = 'PY060';
    END IF;
    SELECT * INTO v_series FROM inv_series WHERE series_code = p_profile->>'series_code';
    IF NOT FOUND OR v_series.kind <> 'invoice' OR v_series.mode <> p_profile->>'mode' THEN
        RAISE EXCEPTION 'series "%" is not an invoice series of mode %.', p_profile->>'series_code', p_profile->>'mode' USING ERRCODE = 'PY060';
    END IF;

    INSERT INTO customer_pricing_plans (tenant_id, platform_code, pricing_plan_id, subscription_pricing_plan_id, started_at, created_at, created_by)
    VALUES (p_tenant_id, p_platform_code, v_spp.pricing_plan_id, v_spp.id, p_anchor, p_anchor, p_actor);
    INSERT INTO ent_entitlements (tenant_id, platform_code, product, status, plan_ref, subscription_pricing_plan_id, started_at, current_period_end,
                                  billing_mode, billing_profile, next_billing_at, source, created_at, updated_at, updated_by)
    VALUES (p_tenant_id, p_platform_code, v_product, 'active', 'sub:' || v_spp.id, v_spp.id, p_anchor, NULL, 'postpaid', p_profile,
            _ent_period_at(p_anchor, 1, (v_spp.duration || ' ' || v_spp.duration_uom)::interval), 'payment', p_anchor, p_anchor, p_actor)
    RETURNING * INTO v_ent;
    INSERT INTO ent_activations (entitlement_id, tenant_id, platform_code, product, kind, plan_ref, idempotency_key, request_hash, actor, reason, period_from, created_at)
    VALUES (v_ent.id, p_tenant_id, p_platform_code, v_product, 'enroll', v_ent.plan_ref, p_key, v_hash, p_actor, 'postpaid enrolment', p_anchor, p_anchor);
    PERFORM _ent_emit(v_ent, 'enroll', NULL, jsonb_build_object('actor', p_actor, 'billing_mode', 'postpaid'));
    o_outcome := 'applied'; o_entitlement_id := v_ent.id; o_next_billing_at := v_ent.next_billing_at;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
