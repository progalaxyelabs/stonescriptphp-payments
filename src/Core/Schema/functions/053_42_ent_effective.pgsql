-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _ent_effective (INTERNAL)
--
-- The ONE rule that turns an entitlement row's FACTS into the access decision at a moment in time. ent_get, ent_tick, the payment-restore
-- trigger and the legacy view all use it, so they cannot disagree.
--   suspended / ended          never active
--   postpaid                   follows its invoices: unpaid past ent_past_due_after_days after the due date = past_due (writes still
--                              allowed, a warning); unpaid for ent_read_only_after_days (30) = read_only. Paying restores it.
--   prepaid / comp / trial     active while current_period_end is in the future (or NULL = lifetime); otherwise read_only
--                              (reason trial_expired for a trial, plan_ended otherwise)
-- Error codes are the ones the framework's middleware already uses (READ_ONLY_TRIAL_EXPIRED, READ_ONLY_PLAN_ENDED), plus
-- READ_ONLY_PAYMENT_OVERDUE.
CREATE OR REPLACE FUNCTION _ent_effective(p_ent ent_entitlements, p_as_of TIMESTAMPTZ)
RETURNS TABLE (o_status TEXT, o_reason TEXT, o_read_only BOOLEAN, o_error_code TEXT, o_overdue_since TIMESTAMPTZ) AS $$
DECLARE
    v_due     TIMESTAMPTZ;
    v_is_trial BOOLEAN := (p_ent.status = 'trial' OR p_ent.source = 'trial');
BEGIN
    o_overdue_since := NULL; o_reason := NULL; o_error_code := NULL; o_read_only := FALSE;
    IF p_ent.status = 'suspended' THEN
        o_status := 'suspended'; o_reason := 'suspended'; o_read_only := TRUE; o_error_code := 'READ_ONLY_PLAN_ENDED';
    ELSIF p_ent.status = 'ended' THEN
        o_status := 'ended'; o_reason := 'plan_ended'; o_read_only := TRUE; o_error_code := 'READ_ONLY_PLAN_ENDED';
    ELSIF p_ent.billing_mode = 'postpaid' THEN
        v_due := _ent_overdue(p_ent.id);
        IF v_due IS NOT NULL AND p_as_of >= v_due + make_interval(days => _pay_config_int('ent_read_only_after_days')::int) THEN
            o_status := 'read_only'; o_reason := 'payment_overdue'; o_read_only := TRUE; o_error_code := 'READ_ONLY_PAYMENT_OVERDUE'; o_overdue_since := v_due;
        ELSIF v_due IS NOT NULL AND p_as_of > v_due + make_interval(days => _pay_config_int('ent_past_due_after_days')::int) THEN
            o_status := 'past_due'; o_reason := 'payment_overdue'; o_overdue_since := v_due;
        ELSE
            o_status := 'active';
        END IF;
    ELSIF p_ent.current_period_end IS NULL OR p_ent.current_period_end > p_as_of THEN
        o_status := CASE WHEN v_is_trial THEN 'trial' ELSE 'active' END;
    ELSE
        o_status := 'read_only'; o_read_only := TRUE;
        IF v_is_trial THEN o_reason := 'trial_expired'; o_error_code := 'READ_ONLY_TRIAL_EXPIRED';
        ELSE o_reason := 'plan_ended'; o_error_code := 'READ_ONLY_PLAN_ENDED'; END IF;
    END IF;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql STABLE;
