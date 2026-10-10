-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _wlt_drain_core (INTERNAL; the one place a debit happens)
--
-- Inside a held wallet lock: forfeits credit expired by p_usage_at, checks the spendable balance, and consumes the earliest-expiring grants first
-- (never-expiring last, then the oldest). All-or-nothing: if the balance is short NOTHING is written and the outcome is 'insufficient'.
-- Both wallet_drain (a one-off debit) and wallet_drain_cumulative (a metered debit) call it.
CREATE OR REPLACE FUNCTION _wlt_drain_core(p_wallet BIGINT, p_drain_key TEXT, p_milli BIGINT, p_usage_at TIMESTAMPTZ, p_reason TEXT, p_actor TEXT)
RETURNS TABLE (o_outcome TEXT, o_drain_id BIGINT, o_balance_milli BIGINT) AS $$
DECLARE
    v_d     wlt_drains;
    v_need  BIGINT;
    v_take  BIGINT;
    v_g     wlt_grants;
    v_avail BIGINT;
BEGIN
    PERFORM _wlt_forfeit_expired(p_wallet, p_usage_at);
    SELECT coalesce(sum(remaining_milli), 0) INTO v_avail FROM wlt_grants
     WHERE wallet_id = p_wallet AND remaining_milli > 0 AND granted_at <= p_usage_at AND (expires_at IS NULL OR expires_at > p_usage_at);
    IF v_avail < p_milli THEN
        o_outcome := 'insufficient'; o_drain_id := NULL; o_balance_milli := v_avail;
        RETURN NEXT; RETURN;
    END IF;
    INSERT INTO wlt_drains (wallet_id, drain_key, reason, debited_milli, usage_at, created_by) VALUES (p_wallet, p_drain_key, p_reason, p_milli, p_usage_at, p_actor) RETURNING * INTO v_d;
    v_need := p_milli;
    FOR v_g IN SELECT * FROM wlt_grants
                WHERE wallet_id = p_wallet AND remaining_milli > 0 AND granted_at <= p_usage_at AND (expires_at IS NULL OR expires_at > p_usage_at)
                ORDER BY expires_at NULLS LAST, granted_at, id FOR UPDATE
    LOOP
        EXIT WHEN v_need = 0;
        v_take := least(v_need, v_g.remaining_milli);
        UPDATE wlt_grants SET remaining_milli = remaining_milli - v_take WHERE id = v_g.id;
        INSERT INTO wlt_drain_allocations (drain_id, grant_id, milli) VALUES (v_d.id, v_g.id, v_take);
        v_need := v_need - v_take;
    END LOOP;
    PERFORM _ledger_post('drain', 'drain:' || v_d.id, p_usage_at, jsonb_build_array(
        jsonb_build_object('account', 'wallet:' || p_wallet, 'amount_milli', -p_milli),
        jsonb_build_object('account', 'sink:consumption', 'amount_milli', p_milli)));
    o_outcome := 'applied'; o_drain_id := v_d.id; o_balance_milli := v_avail - p_milli;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
