-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _ent_tick (INTERNAL; run by bin/pay-entitlement tick)
--
-- Persists the effective status of entitlements whose snapshot is stale (trial/active -> read_only when a period lapsed; postpaid active ->
-- past_due -> read_only as invoices age) and appends an entitlement.changed event per change, so a domain consumer reacts without polling
-- ent_get. It works in CURSOR batches: _ent_tick(as_of, limit, after_id) examines up to `limit` rows with id > after_id and returns how many it
-- examined, how many it changed and the last id it examined; the runner repeats with that cursor until a batch examines fewer than `limit`, so
-- EVERY row is processed however many there are. A row another transaction holds is skipped this pass (SKIP LOCKED) and met on the next pass.
-- p_as_of is clamped to now() + pay_clock_skew_seconds, so a future date given on the command line cannot persist a state that is not true yet.
-- Access decisions never wait for a tick (ent_get derives the same answer from the facts); the tick is visibility and events.
CREATE OR REPLACE FUNCTION _ent_tick(p_as_of TIMESTAMPTZ DEFAULT now(), p_limit INTEGER DEFAULT 500, p_after_id BIGINT DEFAULT 0)
RETURNS TABLE (o_examined INTEGER, o_changed INTEGER, o_last_id BIGINT) AS $$
DECLARE
    v_ent ent_entitlements;
    v_eff RECORD;
    v_from TEXT;
    v_as_of TIMESTAMPTZ := _pay_clamp_future(p_as_of);       -- a future date means nothing (and null means now)
BEGIN
    o_examined := 0; o_changed := 0; o_last_id := p_after_id;
    FOR v_ent IN
        SELECT * FROM ent_entitlements WHERE id > p_after_id AND status IN ('trial', 'active', 'past_due', 'read_only') ORDER BY id LIMIT p_limit FOR UPDATE SKIP LOCKED
    LOOP
        o_examined := o_examined + 1; o_last_id := v_ent.id;
        SELECT * INTO v_eff FROM _ent_effective(v_ent, v_as_of);
        IF v_eff.o_status <> v_ent.status THEN
            v_from := v_ent.status;
            UPDATE ent_entitlements SET status = v_eff.o_status, updated_at = greatest(v_as_of, updated_at), updated_by = '_ent_tick' WHERE id = v_ent.id RETURNING * INTO v_ent;
            PERFORM _ent_emit(v_ent, 'tick', NULL, jsonb_build_object('from', v_from, 'reason', v_eff.o_reason));
            o_changed := o_changed + 1;
        END IF;
    END LOOP;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
