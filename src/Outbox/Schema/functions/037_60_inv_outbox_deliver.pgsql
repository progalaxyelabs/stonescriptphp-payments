-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Outbox :: functions :: function inv_outbox_deliver — split from 037_invoice_outbox_intimation.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: DURABLE product->central invoice INTIMATION via the
--   TRANSACTIONAL OUTBOX pattern (forward), the idempotent central APPLY, and the
--   symmetric REVERSE paid-status sync (central->product).
--
-- === WHY ===
-- Invoices are ALWAYS generated at the product/service platform (each
-- consuming product owns its own billing events). A CENTRAL system (the
-- merchant-of-record + CRM chase source) MUST be intimated IMMEDIATELY and RELIABLY the
-- moment an invoice is issued — never fire-and-forget, never lost, never
-- duplicated. That is the durable-job-lifecycle law (every job -> a terminal
-- state; flush + tombstone; no silent drop) applied to CROSS-SERVICE sync.
--
-- === THE PATTERN ===
-- Fire-and-forget (issue the invoice, THEN try to POST to central) can lose the
-- intimation if the process dies between the commit and the POST, or double-send
-- on a retry. The TRANSACTIONAL OUTBOX removes that gap: the intimation is written
-- as a row in the SAME database transaction that issues the invoice, so it commits
-- atomically WITH the invoice — it can never exist without the invoice, nor the
-- invoice without it. A separate relay then drains the outbox to central with
-- at-least-once delivery + idempotent apply, giving effectively-exactly-once.
--
-- === TWO-DB REALITY (out of scope here — modelled in one DB on purpose) ===
-- In production the PRODUCT db and the CENTRAL db are SEPARATE. The product owns
-- inv_outbox; a relay worker ships each pending row over HTTP to central; central
-- owns central_minimal_invoices + central_apply_intimation. The reverse leg
-- (paid) originates at central (the central pay domain captures the payment) and
-- is shipped back to the product. This prototype is a SINGLE db, so we MODEL both
-- sides here — a product-side outbox and a simulated central apply — precisely so
-- the guarantees (atomic enqueue, exactly-one central row, safe retry, no drop)
-- are PROVABLE end to end. The only thing the real split adds is an HTTP hop and
-- two connection strings; the SQL contracts below are exactly what each side runs.
--
-- === ECOSYSTEM LAW honoured ===
-- Every VALUE is DATA: the outbox state set + which states are claimable/terminal
-- (inv_outbox_statuses), the delivery DIRECTIONS (inv_outbox_directions), WHICH
-- invoice statuses raise a forward intimation (inv_outbox_intimation_statuses),
-- and the retry ceiling max_attempts (inv_outbox_config) are ALL rows — never
-- literals in a body. Function bodies carry only FORMULAE + structural control
-- tokens ('to_central','pending','invoice_issued', ...), exactly like the tax
-- engine's 'intrastate'/'no_tax' mode tokens. Integer paisa throughout.
--
-- === NO now()/CURRENT_DATE ===
-- The enqueue trigger cannot see the caller's timestamp param, so it stamps the
-- outbox row from a timestamp ALREADY on the invoice row: NEW.issued_at (the issue
-- moment, itself a caller-supplied [NOW-CANDIDATE]). Every backoff instant
-- (next_attempt_at) and delivery instant (delivered_at) is a CALLER-supplied
-- param on the lifecycle functions — the relay worker owns "now". now-candidates
-- are TAGGED [NOW-CANDIDATE] for the step-2 now() substitution.
--
-- New custom SQLSTATEs (continuing the ERxxx scheme; max in use before this file
-- was ER061):
--   ER062  outbox job not found                                          -> 404
--   ER063  illegal outbox job state change (marking a finished job)       -> 409
--   ER064  central intimation payload is missing a required field         -> 400

-- =====================================================================
-- 8. THE RELAY DELIVER STEP + CONSISTENCY / DEAD-LETTER SURFACES
-- =====================================================================
-- inv_outbox_deliver: one relay step for a single claimed job. Injects the event
-- 'seq' (the row id) into the envelope, DISPATCHES on direction to the correct far
-- side apply, then marks the job delivered — all in one transaction, so a far-side
-- apply that succeeds is always paired with the mark (no lost ACK). Idempotent on
-- an already-delivered job. In the real split this is the HTTP POST; here it is an
-- in-DB call so the whole loop is provable.

CREATE OR REPLACE FUNCTION inv_outbox_deliver(p_id BIGINT, p_at TIMESTAMPTZ)
RETURNS TEXT AS $$
DECLARE
    v_o       inv_outbox;
    v_envelope JSONB;
BEGIN
    SELECT * INTO v_o FROM inv_outbox WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'outbox job % does not exist', p_id USING ERRCODE = 'ER062';
    END IF;
    IF v_o.status = 'delivered' THEN
        RETURN 'delivered';   -- idempotent
    END IF;
    IF (SELECT is_terminal FROM inv_outbox_statuses WHERE status = v_o.status) THEN
        RAISE EXCEPTION 'outbox job % is terminal ("%") and cannot be delivered.', p_id, v_o.status USING ERRCODE = 'ER063';
    END IF;

    v_envelope := v_o.payload || jsonb_build_object('seq', v_o.id);
    CASE v_o.direction
        WHEN 'to_central' THEN PERFORM central_apply_intimation(v_envelope, p_at);
        WHEN 'to_product' THEN PERFORM product_apply_paid(v_envelope, p_at);
    END CASE;

    RETURN inv_outbox_mark_delivered(p_id, p_at);
END;
$$ LANGUAGE plpgsql;
