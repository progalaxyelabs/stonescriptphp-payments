-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _ledger_post (INTERNAL)
-- Writes one balanced posting: p_entries is a JSON array of {account, amount_milli}; the amounts must sum to zero (PY072), also enforced
-- at commit by a deferred constraint trigger.
CREATE OR REPLACE FUNCTION _ledger_post(p_kind TEXT, p_ref TEXT, p_at TIMESTAMPTZ, p_entries JSONB) RETURNS BIGINT AS $$
DECLARE
    v_txn BIGINT;
    v_sum NUMERIC;
BEGIN
    SELECT coalesce(sum((e->>'amount_milli')::numeric), 0) INTO v_sum FROM jsonb_array_elements(p_entries) e;
    IF v_sum <> 0 OR jsonb_array_length(p_entries) < 2 THEN
        RAISE EXCEPTION 'ledger posting "%" does not balance (sum %).', p_ref, v_sum USING ERRCODE = 'PY072';
    END IF;
    INSERT INTO ledger_txns (kind, ref, at) VALUES (p_kind, p_ref, p_at) RETURNING id INTO v_txn;
    INSERT INTO ledger_entries (txn_id, account, amount_milli)
    SELECT v_txn, e->>'account', (e->>'amount_milli')::bigint FROM jsonb_array_elements(p_entries) e;
    RETURN v_txn;
END;
$$ LANGUAGE plpgsql;
