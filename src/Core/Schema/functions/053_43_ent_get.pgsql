-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: ent_get (PUBLIC, read-only)
--
-- THE entitlement read: what the access middleware, an offline-licence reader and a scan-credit reader all call. One row.
--   o_found      false when the tenant has no entitlement row: then the platform's missing mode (_ent_missing_mode: pay_config 'ent_missing_mode:<platform>', else 'ent_missing_mode') decides (read_only, the
--                framework's default, or allow) and o_status is 'none'
--   o_status     effective status at p_as_of: trial | active | past_due | read_only | ended | suspended | none
--   o_read_only  true = writes must be refused (423) while reads still work
--   o_error_code READ_ONLY_TRIAL_EXPIRED | READ_ONLY_PLAN_ENDED | READ_ONLY_PAYMENT_OVERDUE | READ_ONLY_NO_SUBSCRIPTION (NULL when writes are allowed)
--   o_days_remaining  whole days left when there is an end in the future
CREATE OR REPLACE FUNCTION ent_get(p_tenant_id UUID, p_platform_code VARCHAR(50), p_product TEXT DEFAULT 'default', p_as_of TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (
    o_found BOOLEAN, o_status TEXT, o_stored_status TEXT, o_reason TEXT, o_read_only BOOLEAN, o_error_code TEXT, o_is_trial BOOLEAN,
    o_plan_ref TEXT, o_period_end TIMESTAMPTZ, o_days_remaining INTEGER, o_source TEXT, o_overdue_since TIMESTAMPTZ, o_billing_mode TEXT
) AS $$
DECLARE
    v_ent ent_entitlements;
    v_eff RECORD;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR btrim(p_platform_code) = '' THEN
        RAISE EXCEPTION 'ent_get: tenant and platform are required.' USING ERRCODE = 'PY060';
    END IF;
    SELECT * INTO v_ent FROM ent_entitlements WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code AND product = coalesce(p_product, 'default');
    IF NOT FOUND THEN
        o_found := FALSE; o_status := 'none'; o_stored_status := NULL; o_is_trial := FALSE; o_plan_ref := NULL; o_period_end := NULL;
        o_days_remaining := NULL; o_source := NULL; o_overdue_since := NULL; o_billing_mode := NULL;
        IF _ent_missing_mode(p_platform_code) = 'allow' THEN
            o_read_only := FALSE; o_reason := NULL; o_error_code := NULL;
        ELSE
            o_read_only := TRUE; o_reason := 'no_subscription'; o_error_code := 'READ_ONLY_NO_SUBSCRIPTION';
        END IF;
        RETURN NEXT; RETURN;
    END IF;
    SELECT * INTO v_eff FROM _ent_effective(v_ent, coalesce(p_as_of, now()));
    o_found := TRUE; o_status := v_eff.o_status; o_stored_status := v_ent.status; o_reason := v_eff.o_reason;
    o_read_only := v_eff.o_read_only; o_error_code := v_eff.o_error_code;
    o_is_trial := (v_ent.status = 'trial' OR v_ent.source = 'trial'); o_plan_ref := v_ent.plan_ref; o_period_end := v_ent.current_period_end;
    o_days_remaining := CASE WHEN v_ent.current_period_end IS NOT NULL AND v_ent.current_period_end > coalesce(p_as_of, now()) AND NOT v_eff.o_read_only
                             THEN ceil(extract(epoch FROM (v_ent.current_period_end - coalesce(p_as_of, now()))) / 86400)::int END;
    o_source := v_ent.source; o_overdue_since := v_eff.o_overdue_since; o_billing_mode := v_ent.billing_mode;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql STABLE;
