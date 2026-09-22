-- package: progalaxyelabs/stonescriptphp-pay v0.3.0
-- stonescriptphp-pay :: Capture :: functions :: pay_record_captured_payment
--
-- Records a VERIFIED gateway capture exactly once. This function is the
-- entire idempotent-capture primitive's logic — a caller (webhook route ->
-- domain function, e.g. sub_activate, scan_credit_purchase_apply,
-- inv_record_payment) calls this FIRST, inside its own transaction, then
-- performs its own business side effect (extend a subscription, credit a
-- wallet, transition an invoice) ONLY when `o_already_applied` is false.
--
-- Composition contract (read this before wiring a new consumer):
--   1. Call pay_record_captured_payment(...) as the FIRST statement of your
--      domain function.
--   2. If o_already_applied = true: this exact (gateway_code,
--      gateway_txn_ref) was already recorded by an earlier call (a webhook
--      retry, or a concurrent racing call that committed first) — return
--      your own idempotent "already applied" response using the domain
--      state as it stands NOW (do not repeat your side effect, do not
--      recompute it from o_amount_minor/o_reference — those are reported
--      for observability, not to be re-applied).
--   3. If o_already_applied = false: this call is the ONE, exactly-once
--      winner for this gateway transaction — perform your side effect now,
--      in the SAME transaction (so a crash between this insert and your
--      side effect rolls BOTH back together, never leaving a "recorded but
--      not applied" orphan).
--
-- CONCURRENCY DESIGN (why this is simpler than the two hand-rolled
-- references it supersedes — one a credit-purchase-apply
-- function (advisory-lock + partial-UNIQUE + inner BEGIN/EXCEPTION savepoint)
-- and another a payment-capture function (SELECT FOR UPDATE + conditional
-- UPDATE...WHERE...RETURNING)): both of those references couple the
-- idempotency gate to a SIDE EFFECT in the same statement group (a wallet
-- credit, a status flip) and therefore need machinery to UNDO that side
-- effect when they lose a race after already starting it. This function has
-- NO side effect of its own — it is pure "record the fact, once" — so the
-- plain, standard Postgres idiom for that is sufficient and complete:
-- `INSERT ... ON CONFLICT (unique key) DO NOTHING`. Two transactions racing
-- to insert the SAME (gateway_code, gateway_txn_ref) serialize at the
-- unique index itself: whichever commits first wins the row; the second's
-- INSERT blocks until the first's transaction ends, then (finding the row
-- already there) conflicts and inserts nothing — `RETURNING` yields no row,
-- `FOUND` is false, and this function re-reads and reports the WINNER's own
-- committed facts. This is correct under every concurrent interleaving
-- Postgres allows for a unique index, with no advisory lock, no row lock,
-- and no exception handling required at this layer. (A CALLER that adds its
-- own side effect after the o_already_applied=false branch is what still
-- needs the composition discipline above — that responsibility cannot be
-- pushed into this shared primitive, precisely because pay does not know
-- what that side effect is.)
CREATE OR REPLACE FUNCTION pay_record_captured_payment(
    p_gateway_code    TEXT,
    p_gateway_txn_ref TEXT,
    p_reference       TEXT,
    p_amount_minor    BIGINT,
    p_currency        TEXT,
    p_status          TEXT,
    p_captured_at     TIMESTAMPTZ,
    p_created_by      TEXT,
    p_raw_payload     JSONB DEFAULT NULL
)
RETURNS TABLE (
    o_payment_id      BIGINT,
    o_already_applied BOOLEAN,
    o_reference       TEXT,
    o_amount_minor    BIGINT,
    o_currency        TEXT,
    o_status          TEXT,
    o_captured_at     TIMESTAMPTZ
)
LANGUAGE plpgsql AS $$
DECLARE
    v_row pay_captured_payments;
BEGIN
    IF p_status NOT IN ('success', 'failed') THEN
        RAISE EXCEPTION 'pay_record_captured_payment: status "%" is invalid (expected ''success'' or ''failed'').', p_status
            USING ERRCODE = 'PY001';
    END IF;

    IF p_gateway_code IS NULL OR p_gateway_code = '' THEN
        RAISE EXCEPTION 'pay_record_captured_payment: gateway_code is required.' USING ERRCODE = 'PY002';
    END IF;

    IF p_gateway_txn_ref IS NULL OR p_gateway_txn_ref = '' THEN
        RAISE EXCEPTION 'pay_record_captured_payment: gateway_txn_ref is required.' USING ERRCODE = 'PY003';
    END IF;

    -- Atomic insert-if-absent. See the docblock above for why this ONE
    -- statement is the complete concurrency guarantee for this primitive.
    INSERT INTO pay_captured_payments (
        gateway_code, gateway_txn_ref, reference, amount_minor, currency,
        status, captured_at, raw_payload, created_by
    ) VALUES (
        p_gateway_code, p_gateway_txn_ref, p_reference, p_amount_minor, p_currency,
        p_status, p_captured_at, p_raw_payload, p_created_by
    )
    ON CONFLICT (gateway_code, gateway_txn_ref) DO NOTHING
    RETURNING * INTO v_row;

    IF FOUND THEN
        -- This call is the exactly-once winner.
        RETURN QUERY SELECT v_row.id, false, v_row.reference, v_row.amount_minor, v_row.currency, v_row.status, v_row.captured_at;
        RETURN;
    END IF;

    -- Lost the race (or a genuine replay) — report the WINNING row's own
    -- committed facts, never this call's own input values, so a caller can
    -- never be told a different amount/reference/status than what was
    -- actually recorded for this gateway transaction.
    SELECT * INTO v_row FROM pay_captured_payments
     WHERE gateway_code = p_gateway_code AND gateway_txn_ref = p_gateway_txn_ref;

    RETURN QUERY SELECT v_row.id, true, v_row.reference, v_row.amount_minor, v_row.currency, v_row.status, v_row.captured_at;
END;
$$;
