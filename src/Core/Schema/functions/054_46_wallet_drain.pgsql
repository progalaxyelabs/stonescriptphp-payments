-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: wallet_drain, wallet_drain_cumulative (PUBLIC)
--
-- wallet_drain: a one-off debit (a scan, a purchase of a service). HARD STOP: if the spendable balance at p_usage_at is less than the debit, NOTHING
-- is written and the outcome is 'insufficient' - the domain decides what to stop. Never overdraws.
--   * serialised per wallet (row lock); idempotent per p_drain_key (a repeat debits once; a different amount under the key is refused, PY071)
--   * p_usage_at is clamped to now() + pay_clock_skew_seconds: a future usage time means nothing
--   * credit expired by p_usage_at is forfeited first (reported, not deleted) and is not spendable from that exact instant
--   * BACKDATED DRAINS: a drain dated before an expiry that has NOT yet been swept may still use that credit; once the expiry is swept (forfeited) the credit
--     is gone and a drain dated before it is refused for that credit. Callers should pass the real usage time (normally now); a late-arriving usage record
--     for a period whose credit has since expired is the one case where the customer is charged less than the strict timeline would allow
--     and that is the intended, customer-favourable, outcome.
--
-- wallet_drain_cumulative: THE metering entry point (a per-minute compute tick, a scan counter). The caller reports the meter's CUMULATIVE usage and the
-- rate as a fraction (rate_num / rate_den milli-credits per unit); the wallet debits  div(cumulative x rate_num, rate_den)  minus what that meter has
-- already been debited, so the total debited is ALWAYS exactly floor(total usage x rate), never the sum of per-tick roundings (which drifts).
--   * idempotent per p_tick_key (a repeated tick returns its original answer; the same key with another cumulative is refused, PY071)
--   * cumulative must not go backwards (PY071)
--   * an OLDER cumulative under a NEW tick key (at-least-once queues deliver out of order: tick 5 before tick 4) is a no-op, outcome 'superseded': the newer
--     tick already charged for everything the older one covers, so charging again would double-bill and failing would only make the caller retry forever.
--     It is recorded (wlt_meter_ticks.superseded) so the audit shows it. This cannot hide a meter RESET, because a reset is not a late tick: a meter that restarts
--     from zero, or whose rate changes, must use a NEW meter_key (retire the old one with _wlt_meter_close, which then refuses further ticks, PY071)
--   * if the balance cannot cover the delta the outcome is 'insufficient', NOTHING is written and the meter does not advance, so the next tick
--     asks for the whole shortfall again: no usage is ever forgiven or double-charged
-- TICKS CARRY usage_at = NOW. A retried tick must be sent with the moment of the RETRY (or the same value as its first attempt only if that is still within
-- the clock skew): re-sending the original time of an old attempt asks the wallet about a past moment, which can resurrect credit that has since expired.
-- Idempotency is carried by the tick key, never by the timestamp.
-- All amounts are milli-credits.
-- Only platform server code may call these, with the tenant it has authenticated (README).
CREATE OR REPLACE FUNCTION wallet_drain(p_tenant_id UUID, p_platform_code VARCHAR(50), p_drain_key TEXT, p_milli BIGINT, p_usage_at TIMESTAMPTZ,
                                        p_reason TEXT, p_actor TEXT)
RETURNS TABLE (o_outcome TEXT, o_drain_id BIGINT, o_debited_milli BIGINT, o_balance_milli BIGINT) AS $$
DECLARE
    v_wallet BIGINT;
    v_d      wlt_drains;
    v_at     TIMESTAMPTZ := _pay_clamp_future(p_usage_at);
    v_r      RECORD;
BEGIN
    IF p_drain_key IS NULL OR btrim(p_drain_key) = '' OR p_milli IS NULL OR p_milli <= 0 OR p_usage_at IS NULL OR p_actor IS NULL OR btrim(p_actor) = '' THEN
        RAISE EXCEPTION 'wallet_drain: key, a positive amount, usage time and actor are required.' USING ERRCODE = 'PY070';
    END IF;
    v_wallet := _wlt_wallet_lock(p_tenant_id, p_platform_code);
    SELECT * INTO v_d FROM wlt_drains WHERE wallet_id = v_wallet AND drain_key = p_drain_key;
    IF FOUND THEN
        IF v_d.debited_milli <> p_milli THEN
            RAISE EXCEPTION 'drain key "%" was already used for a debit of % milli-credits, not %.', p_drain_key, v_d.debited_milli, p_milli USING ERRCODE = 'PY071';
        END IF;
        o_outcome := 'already_applied'; o_drain_id := v_d.id; o_debited_milli := v_d.debited_milli;
        SELECT coalesce(sum(remaining_milli), 0) INTO o_balance_milli FROM wlt_grants WHERE wallet_id = v_wallet AND (expires_at IS NULL OR expires_at > v_at) AND granted_at <= v_at;
        RETURN NEXT; RETURN;
    END IF;
    SELECT * INTO v_r FROM _wlt_drain_core(v_wallet, p_drain_key, p_milli, v_at, p_reason, p_actor);
    o_outcome := v_r.o_outcome; o_drain_id := v_r.o_drain_id; o_debited_milli := CASE WHEN v_r.o_outcome = 'applied' THEN p_milli ELSE 0 END; o_balance_milli := v_r.o_balance_milli;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION wallet_drain_cumulative(p_tenant_id UUID, p_platform_code VARCHAR(50), p_meter_key TEXT, p_tick_key TEXT, p_cumulative NUMERIC,
                                                   p_rate_num BIGINT, p_rate_den BIGINT, p_usage_at TIMESTAMPTZ, p_reason TEXT, p_actor TEXT)
RETURNS TABLE (o_outcome TEXT, o_debited_milli BIGINT, o_total_debited_milli BIGINT, o_balance_milli BIGINT) AS $$
DECLARE
    v_wallet BIGINT;
    v_meter  wlt_meters;
    v_tick   wlt_meter_ticks;
    v_at     TIMESTAMPTZ := _pay_clamp_future(p_usage_at);
    v_target BIGINT;
    v_delta  BIGINT;
    v_r      RECORD;
BEGIN
    IF p_meter_key IS NULL OR btrim(p_meter_key) = '' OR p_tick_key IS NULL OR btrim(p_tick_key) = '' OR p_cumulative IS NULL OR p_cumulative < 0
       OR p_rate_num IS NULL OR p_rate_num <= 0 OR p_rate_den IS NULL OR p_rate_den <= 0 OR p_usage_at IS NULL OR p_actor IS NULL OR btrim(p_actor) = '' THEN
        RAISE EXCEPTION 'wallet_drain_cumulative: meter, tick, a non-negative cumulative, a positive rate (num/den), usage time and actor are required.' USING ERRCODE = 'PY070';
    END IF;
    v_wallet := _wlt_wallet_lock(p_tenant_id, p_platform_code);
    INSERT INTO wlt_meters (wallet_id, meter_key, rate_num, rate_den) VALUES (v_wallet, p_meter_key, p_rate_num, p_rate_den) ON CONFLICT (wallet_id, meter_key) DO NOTHING;
    SELECT * INTO v_meter FROM wlt_meters WHERE wallet_id = v_wallet AND meter_key = p_meter_key FOR UPDATE;

    SELECT * INTO v_tick FROM wlt_meter_ticks WHERE meter_id = v_meter.id AND tick_key = p_tick_key;
    IF FOUND THEN
        IF v_tick.cumulative <> p_cumulative THEN
            RAISE EXCEPTION 'meter tick "%" was already recorded at cumulative %, not %.', p_tick_key, v_tick.cumulative, p_cumulative USING ERRCODE = 'PY071';
        END IF;
        o_outcome := CASE WHEN v_tick.superseded THEN 'superseded' ELSE 'already_applied' END; o_debited_milli := v_tick.delta_milli; o_total_debited_milli := v_meter.debited_milli;
        SELECT coalesce(sum(remaining_milli), 0) INTO o_balance_milli FROM wlt_grants WHERE wallet_id = v_wallet AND (expires_at IS NULL OR expires_at > v_at) AND granted_at <= v_at;
        RETURN NEXT; RETURN;
    END IF;
    IF v_meter.closed_at IS NOT NULL THEN
        RAISE EXCEPTION 'meter "%" is closed: a reset or a rate change starts a new meter key.', p_meter_key USING ERRCODE = 'PY071';
    END IF;
    IF p_cumulative < v_meter.cumulative THEN
        -- out of order: the newer tick already charged for this usage. Record it, charge nothing.
        INSERT INTO wlt_meter_ticks (meter_id, tick_key, cumulative, delta_milli, superseded) VALUES (v_meter.id, p_tick_key, p_cumulative, 0, TRUE);
        o_outcome := 'superseded'; o_debited_milli := 0; o_total_debited_milli := v_meter.debited_milli;
        SELECT coalesce(sum(remaining_milli), 0) INTO o_balance_milli FROM wlt_grants WHERE wallet_id = v_wallet AND (expires_at IS NULL OR expires_at > v_at) AND granted_at <= v_at;
        RETURN NEXT; RETURN;
    END IF;
    IF v_meter.rate_num <> p_rate_num OR v_meter.rate_den <> p_rate_den THEN
        RAISE EXCEPTION 'meter "%": the rate changed from %/% to %/%: use a new meter key for a new rate.', p_meter_key, v_meter.rate_num, v_meter.rate_den, p_rate_num, p_rate_den USING ERRCODE = 'PY071';
    END IF;

    v_target := div(p_cumulative * p_rate_num, p_rate_den::numeric)::bigint;
    v_delta := v_target - v_meter.debited_milli;
    IF v_delta = 0 THEN
        INSERT INTO wlt_meter_ticks (meter_id, tick_key, cumulative, delta_milli) VALUES (v_meter.id, p_tick_key, p_cumulative, 0);
        UPDATE wlt_meters SET cumulative = p_cumulative WHERE id = v_meter.id;
        o_outcome := 'applied'; o_debited_milli := 0; o_total_debited_milli := v_meter.debited_milli;
        SELECT coalesce(sum(remaining_milli), 0) INTO o_balance_milli FROM wlt_grants WHERE wallet_id = v_wallet AND (expires_at IS NULL OR expires_at > v_at) AND granted_at <= v_at;
        RETURN NEXT; RETURN;
    END IF;
    SELECT * INTO v_r FROM _wlt_drain_core(v_wallet, 'm:' || v_meter.id || ':' || p_tick_key, v_delta, v_at, coalesce(p_reason, 'meter ' || p_meter_key), p_actor);
    IF v_r.o_outcome <> 'applied' THEN
        o_outcome := v_r.o_outcome; o_debited_milli := 0; o_total_debited_milli := v_meter.debited_milli; o_balance_milli := v_r.o_balance_milli;
        RETURN NEXT; RETURN;                                   -- nothing written, the meter has not advanced
    END IF;
    INSERT INTO wlt_meter_ticks (meter_id, tick_key, cumulative, delta_milli, drain_id) VALUES (v_meter.id, p_tick_key, p_cumulative, v_delta, v_r.o_drain_id);
    UPDATE wlt_meters SET cumulative = p_cumulative, debited_milli = debited_milli + v_delta WHERE id = v_meter.id;
    o_outcome := 'applied'; o_debited_milli := v_delta; o_total_debited_milli := v_meter.debited_milli + v_delta; o_balance_milli := v_r.o_balance_milli;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
