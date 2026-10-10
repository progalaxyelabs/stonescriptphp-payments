-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _ent_apply_period (INTERNAL)
--
-- The single writer of an entitlement period, called by pay_apply_capture (kind payment), ent_comp_activate (comp), ent_start_trial
-- (trial) and _ent_import_legacy. Serialised per (tenant, platform, product) by an advisory lock, idempotent per (tenant, platform,
-- key): the same key with the same request returns the original activation (o_already), the same key with a different request is
-- refused (PY062).
--   * A new period STACKS onto the remaining time: it starts at the later of p_at and the current period end.
--   * p_interval NULL = a lifetime licence (no end). A lifetime entitlement stays lifetime.
--   * A PAYMENT for a suspended entitlement is refused (PY066): the suspension may be for abuse, fraud or a chargeback, so paid money neither
--     reinstates access silently nor is absorbed - pay_apply_capture queues it for refund as 'paid_while_suspended' (alerted) and a human decides.
--     A comp for a suspended entitlement is recorded and the suspension stays. An ended entitlement is reactivated by a new period.
--   * LATE APPLY never costs the customer paid time (kind 'payment'): the period is anchored at the later of the capture time and the previous
--     period end; if the apply happens more than pay_config 'ent_late_apply_grace_hours' (24) after the capture (a backlog, a replay), it is
--     anchored at the apply time instead, so the customer receives the full period they paid for.
--   * Period arithmetic runs in the billing zone (pay_config 'billing_timezone'), independent of the session TimeZone.
--   * A postpaid entitlement follows its invoices and takes no period grant (PY061).
-- Writes one ent_activations audit row; emits entitlement.changed except for kind 'payment' (pay_apply_capture emits its own).
CREATE OR REPLACE FUNCTION _ent_apply_period(
    p_tenant UUID, p_platform VARCHAR(50), p_product TEXT, p_kind TEXT, p_plan_ref TEXT, p_spp_id BIGINT, p_interval INTERVAL,
    p_status TEXT, p_source TEXT, p_at TIMESTAMPTZ, p_key TEXT, p_hash TEXT, p_actor TEXT, p_reason TEXT, p_invoice BIGINT, p_payment BIGINT
) RETURNS TABLE (o_activation_id BIGINT, o_entitlement_id BIGINT, o_period_from TIMESTAMPTZ, o_period_to TIMESTAMPTZ, o_already BOOLEAN) AS $$
DECLARE
    v_act  ent_activations;
    v_ent  ent_entitlements;
    v_from TIMESTAMPTZ;
    v_to   TIMESTAMPTZ;
    v_status TEXT;
    v_tz   TEXT := _pay_billing_tz();
    v_late BOOLEAN := p_kind = 'payment' AND now() - p_at > make_interval(hours => _pay_config_int('ent_late_apply_grace_hours')::int);
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('ent:' || p_tenant::text || ':' || p_platform || ':' || p_product, 0));

    SELECT * INTO v_act FROM ent_activations WHERE tenant_id = p_tenant AND platform_code = p_platform AND idempotency_key = p_key;
    IF FOUND THEN
        IF v_act.request_hash <> p_hash THEN
            RAISE EXCEPTION 'idempotency key "%" was already used for a different entitlement request.', p_key USING ERRCODE = 'PY062';
        END IF;
        o_activation_id := v_act.id; o_entitlement_id := v_act.entitlement_id; o_period_from := v_act.period_from; o_period_to := v_act.period_to; o_already := TRUE;
        RETURN NEXT; RETURN;
    END IF;

    SELECT * INTO v_ent FROM ent_entitlements WHERE tenant_id = p_tenant AND platform_code = p_platform AND product = p_product FOR UPDATE;
    IF NOT FOUND THEN
        v_from := CASE WHEN v_late THEN now() ELSE p_at END;
        v_to := CASE WHEN p_interval IS NULL THEN NULL ELSE ((v_from AT TIME ZONE v_tz) + p_interval) AT TIME ZONE v_tz END;
        INSERT INTO ent_entitlements (tenant_id, platform_code, product, status, plan_ref, subscription_pricing_plan_id, started_at, current_period_end,
                                      billing_mode, source, created_at, updated_at, updated_by)
        VALUES (p_tenant, p_platform, p_product, p_status, p_plan_ref, p_spp_id, p_at, v_to, 'prepaid', p_source, p_at, p_at, p_actor)
        RETURNING * INTO v_ent;
    ELSE
        IF v_ent.billing_mode = 'postpaid' THEN
            RAISE EXCEPTION 'entitlement % is postpaid: access follows its invoices and takes no period grant.', v_ent.id USING ERRCODE = 'PY061';
        END IF;
        IF v_ent.status = 'suspended' AND p_kind = 'payment' THEN
            RAISE EXCEPTION 'entitlement % is suspended: a payment does not lift a suspension; it is queued for a human.', v_ent.id USING ERRCODE = 'PY066';
        END IF;
        v_from := greatest(CASE WHEN v_late THEN now() ELSE p_at END, coalesce(v_ent.current_period_end, p_at));
        IF v_ent.current_period_end IS NULL AND v_ent.status <> 'ended' THEN
            v_to := NULL;                                   -- lifetime stays lifetime
        ELSE
            v_to := CASE WHEN p_interval IS NULL THEN NULL ELSE ((v_from AT TIME ZONE v_tz) + p_interval) AT TIME ZONE v_tz END;
        END IF;
        v_status := CASE WHEN v_ent.status = 'suspended' THEN 'suspended' ELSE p_status END;
        UPDATE ent_entitlements SET status = v_status, plan_ref = p_plan_ref, subscription_pricing_plan_id = coalesce(p_spp_id, subscription_pricing_plan_id),
               current_period_end = v_to, source = p_source, updated_at = greatest(p_at, updated_at), updated_by = p_actor
         WHERE id = v_ent.id RETURNING * INTO v_ent;
    END IF;

    INSERT INTO ent_activations (entitlement_id, tenant_id, platform_code, product, kind, plan_ref, idempotency_key, request_hash, actor, reason,
                                 period_from, period_to, invoice_id, payment_id, created_at)
    VALUES (v_ent.id, p_tenant, p_platform, p_product, p_kind, p_plan_ref, p_key, p_hash, p_actor, p_reason, v_from, v_to, p_invoice, p_payment, p_at)
    RETURNING id INTO o_activation_id;
    IF p_kind <> 'payment' THEN
        PERFORM _ent_emit(v_ent, p_kind, NULL, jsonb_build_object('activation_id', o_activation_id, 'actor', p_actor));
    END IF;
    o_entitlement_id := v_ent.id; o_period_from := v_from; o_period_to := v_to; o_already := FALSE;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
