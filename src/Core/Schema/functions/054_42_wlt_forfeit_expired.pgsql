-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _wlt_forfeit_expired (INTERNAL)
-- Inside a held wallet lock: credit whose expires_at is at or before p_as_of and which is still unspent is FORFEITED: moved out of
-- remaining into forfeited_milli, recorded in wlt_forfeits (reported, not deleted) and posted to the ledger. Returns the milli forfeited.
CREATE OR REPLACE FUNCTION _wlt_forfeit_expired(p_wallet BIGINT, p_as_of TIMESTAMPTZ) RETURNS BIGINT AS $$
DECLARE
    v_g     wlt_grants;
    v_total BIGINT := 0;
BEGIN
    FOR v_g IN SELECT * FROM wlt_grants WHERE wallet_id = p_wallet AND remaining_milli > 0 AND expires_at IS NOT NULL AND expires_at <= p_as_of ORDER BY id FOR UPDATE
    LOOP
        INSERT INTO wlt_forfeits (wallet_id, grant_id, milli, expired_at) VALUES (p_wallet, v_g.id, v_g.remaining_milli, v_g.expires_at);
        UPDATE wlt_grants SET forfeited_milli = forfeited_milli + remaining_milli, remaining_milli = 0 WHERE id = v_g.id;
        PERFORM _ledger_post('forfeit', 'grant:' || v_g.id, v_g.expires_at, jsonb_build_array(
            jsonb_build_object('account', 'wallet:' || p_wallet, 'amount_milli', -v_g.remaining_milli),
            jsonb_build_object('account', 'sink:forfeiture', 'amount_milli', v_g.remaining_milli)));
        v_total := v_total + v_g.remaining_milli;
    END LOOP;
    RETURN v_total;
END;
$$ LANGUAGE plpgsql;
