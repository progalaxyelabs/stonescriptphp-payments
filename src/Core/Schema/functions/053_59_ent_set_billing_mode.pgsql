-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _ent_set_billing_mode (INTERNAL; bin/pay-entitlement billing-mode)
--
-- Switches an entitlement between prepaid and postpaid. Audited (kind 'mode'), idempotent per key.
--   to postpaid  needs the postpaid plan, the billing profile (as for _ent_enroll_postpaid) and the anchor of the first period. The prepaid period
--                end is cleared: from now on access follows the invoices.
--   to prepaid   needs the moment access runs until (p_period_end) and REFUSES (PY061) while any billed invoice is unpaid: settle or void them first.
CREATE OR REPLACE FUNCTION _ent_set_billing_mode(p_tenant_id UUID, p_platform_code VARCHAR(50), p_product TEXT, p_mode TEXT, p_spp_id BIGINT, p_profile JSONB,
                                                 p_anchor TIMESTAMPTZ, p_period_end TIMESTAMPTZ, p_key TEXT, p_actor TEXT, p_reason TEXT)
RETURNS TABLE (o_outcome TEXT, o_billing_mode TEXT) AS $$
DECLARE
    v_product TEXT := coalesce(p_product, 'default');
    v_hash    TEXT := encode(sha256(convert_to(concat_ws('|', 'mode', coalesce(p_product, 'default'), p_mode, p_spp_id::text, p_profile::text, p_anchor::text, p_period_end::text), 'UTF8')), 'hex');
    v_act     ent_activations;
    v_ent     ent_entitlements;
    v_spp     RECORD;
BEGIN
    IF p_mode IS NULL OR p_mode NOT IN ('prepaid', 'postpaid') OR p_key IS NULL OR btrim(p_key) = '' OR p_actor IS NULL OR btrim(p_actor) = ''
       OR p_reason IS NULL OR btrim(p_reason) = '' OR p_tenant_id IS NULL OR p_platform_code IS NULL THEN
        RAISE EXCEPTION '_ent_set_billing_mode: tenant, platform, mode (prepaid|postpaid), key, actor and reason are required.' USING ERRCODE = 'PY060';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('ent:' || p_tenant_id::text || ':' || p_platform_code || ':' || v_product, 0));
    SELECT * INTO v_act FROM ent_activations WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code AND idempotency_key = p_key;
    IF FOUND THEN
        IF v_act.request_hash <> v_hash THEN
            RAISE EXCEPTION 'idempotency key "%" was already used for a different entitlement request.', p_key USING ERRCODE = 'PY062';
        END IF;
        o_outcome := 'already_applied'; o_billing_mode := p_mode;
        RETURN NEXT; RETURN;
    END IF;
    SELECT * INTO v_ent FROM ent_entitlements WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code AND product = v_product FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'tenant has no entitlement for product "%".', v_product USING ERRCODE = 'PY061';
    END IF;
    IF v_ent.billing_mode = p_mode THEN
        RAISE EXCEPTION 'entitlement is already %.', p_mode USING ERRCODE = 'PY061';
    END IF;

    IF p_mode = 'postpaid' THEN
        IF p_spp_id IS NULL OR p_profile IS NULL OR p_anchor IS NULL THEN
            RAISE EXCEPTION 'switching to postpaid needs the plan, the billing profile and the anchor.' USING ERRCODE = 'PY060';
        END IF;
        IF p_anchor > now() + make_interval(secs => _pay_config_int('pay_clock_skew_seconds')) THEN
            RAISE EXCEPTION 'billing anchor (%) is in the future beyond the clock skew.', p_anchor USING ERRCODE = 'PY064';
        END IF;
        SELECT spp.id, spp.duration, spp.duration_uom INTO v_spp FROM subscription_pricing_plans spp JOIN pricing_plans pp ON pp.id = spp.pricing_plan_id
         WHERE spp.id = p_spp_id AND spp.is_active AND pp.is_active AND NOT pp.is_trial AND spp.is_post_paid;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'plan % is not an active postpaid subscription plan.', p_spp_id USING ERRCODE = 'PY060';
        END IF;
        IF p_profile->>'series_code' IS NULL OR coalesce(p_profile->>'mode', '') NOT IN ('live', 'test') OR p_profile->'buyer' IS NULL
           OR p_profile->>'billing_country_code' IS NULL OR p_profile->>'billing_state' IS NULL OR p_profile->>'hsn_sac' IS NULL OR p_profile->>'gst_rate' IS NULL THEN
            RAISE EXCEPTION 'billing profile needs series_code, mode, buyer, billing_country_code, billing_state, hsn_sac and gst_rate.' USING ERRCODE = 'PY060';
        END IF;
        UPDATE ent_entitlements SET billing_mode = 'postpaid', billing_profile = p_profile, subscription_pricing_plan_id = v_spp.id, plan_ref = 'sub:' || v_spp.id,
               started_at = p_anchor, current_period_end = NULL,
               next_billing_at = _ent_period_at(p_anchor, 1, (v_spp.duration || ' ' || v_spp.duration_uom)::interval),
               billing_failures = 0, billing_retry_at = NULL, billing_last_error = NULL, updated_at = now(), updated_by = p_actor
         WHERE id = v_ent.id RETURNING * INTO v_ent;
    ELSE
        IF p_period_end IS NULL THEN
            RAISE EXCEPTION 'switching to prepaid needs the moment access runs until.' USING ERRCODE = 'PY060';
        END IF;
        IF EXISTS (SELECT 1 FROM ent_billing_runs r JOIN inv_invoices i ON i.id = r.invoice_id WHERE r.entitlement_id = v_ent.id AND i.status IN ('issued', 'due')) THEN
            RAISE EXCEPTION 'entitlement % has unpaid invoices: settle or void them before switching to prepaid.', v_ent.id USING ERRCODE = 'PY061';
        END IF;
        UPDATE ent_entitlements SET billing_mode = 'prepaid', billing_profile = NULL, next_billing_at = NULL, current_period_end = p_period_end,
               billing_failures = 0, billing_retry_at = NULL, billing_last_error = NULL, updated_at = now(), updated_by = p_actor
         WHERE id = v_ent.id RETURNING * INTO v_ent;
    END IF;
    INSERT INTO ent_activations (entitlement_id, tenant_id, platform_code, product, kind, plan_ref, idempotency_key, request_hash, actor, reason, period_from, period_to)
    VALUES (v_ent.id, p_tenant_id, p_platform_code, v_product, 'mode', v_ent.plan_ref, p_key, v_hash, p_actor, p_reason, p_anchor, p_period_end);
    PERFORM _ent_emit(v_ent, 'mode', NULL, jsonb_build_object('actor', p_actor, 'billing_mode', p_mode));
    o_outcome := 'applied'; o_billing_mode := p_mode;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
