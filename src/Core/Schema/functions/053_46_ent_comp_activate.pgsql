-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _ent_comp_activate (INTERNAL; run by bin/pay-entitlement or a platform's own authorised admin route)
--
-- Complimentary activation: grants p_days of access with NO money: no invoice, no payment, no number. Audited (actor and reason are
-- mandatory) and idempotent per activation: the SAME key with the SAME request returns the original activation and extends nothing a
-- second time; the SAME key with a DIFFERENT plan or duration is refused (PY062). The period stacks onto remaining time (see
-- _ent_apply_period). A comp cannot be given to a postpaid entitlement (PY061). p_at must be within pay_clock_skew_seconds of the
-- database clock (PY064). Internal because it gives access away: expose it only behind your own admin authorisation (README, "Admin actions").
-- Returns o_outcome 'applied' | 'already_applied'.
CREATE OR REPLACE FUNCTION _ent_comp_activate(
    p_tenant_id UUID, p_platform_code VARCHAR(50), p_product TEXT, p_plan_ref TEXT, p_days INTEGER,
    p_key TEXT, p_actor TEXT, p_reason TEXT, p_at TIMESTAMPTZ DEFAULT now()
) RETURNS TABLE (o_outcome TEXT, o_activation_id BIGINT, o_status TEXT, o_period_end TIMESTAMPTZ) AS $$
DECLARE
    v_product TEXT := coalesce(p_product, 'default');
    v_r       RECORD;
    v_ent     ent_entitlements;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR btrim(p_platform_code) = '' OR p_key IS NULL OR btrim(p_key) = ''
       OR p_actor IS NULL OR btrim(p_actor) = '' OR p_reason IS NULL OR btrim(p_reason) = '' OR p_at IS NULL THEN
        RAISE EXCEPTION '_ent_comp_activate: tenant, platform, idempotency key, actor, reason and time are required.' USING ERRCODE = 'PY060';
    END IF;
    PERFORM _pay_bound_clock(p_at, 'comp time');
    IF p_plan_ref IS NULL OR p_plan_ref !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,49}$' THEN
        RAISE EXCEPTION '_ent_comp_activate: plan_ref must be 1-50 characters (letters, digits, _ . : -).' USING ERRCODE = 'PY060';
    END IF;
    IF p_days IS NULL OR p_days < 1 OR p_days > 3660 THEN
        RAISE EXCEPTION '_ent_comp_activate: days must be between 1 and 3660 (got %).', p_days USING ERRCODE = 'PY060';
    END IF;
    SELECT * INTO v_r FROM _ent_apply_period(p_tenant_id, p_platform_code, v_product, 'comp', p_plan_ref, NULL, make_interval(days => p_days),
        'active', 'comp', p_at, p_key,
        encode(sha256(convert_to(concat_ws('|', 'comp', v_product, p_plan_ref, p_days::text), 'UTF8')), 'hex'), p_actor, p_reason, NULL, NULL);
    SELECT * INTO v_ent FROM ent_entitlements WHERE id = v_r.o_entitlement_id;
    o_outcome := CASE WHEN v_r.o_already THEN 'already_applied' ELSE 'applied' END;
    o_activation_id := v_r.o_activation_id; o_status := v_ent.status; o_period_end := v_r.o_period_to;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
