-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Outbox :: functions :: function central_record_payment — split from 037_invoice_outbox_intimation.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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
--   ER067  invoice does not belong to the caller's tenant/platform (isolation) -> 403
--
-- TENANT ISOLATION (added 2026-09-22, dev-critique finding): this function
-- has the SAME bare-invoice_id-with-no-tenant-check shape that
-- inv_record_payment (035) was fixed for — central_minimal_invoices already
-- carries tenant_id/platform_code (copied verbatim from the forward
-- intimation, 037_15), so there is no reason not to enforce it here too,
-- even though today's single-DB prototype only exercises this via SQL
-- tests. In the real two-DB split this doc describes (product DB / central
-- DB, separate processes), this is exactly the function a mis-routed or
-- forged central-side webhook/API call would hit.

CREATE OR REPLACE FUNCTION central_record_payment(
    p_invoice_id     BIGINT,
    p_tenant_id      UUID,
    p_platform_code  VARCHAR(50),
    p_gateway_code   TEXT,
    p_gateway_txn_ref TEXT,
    p_amount_minor   BIGINT,
    p_currency       TEXT,
    p_captured_at    TIMESTAMPTZ,   -- BUSINESS INPUT from the gateway
    p_created_by     TEXT,
    p_created_at     TIMESTAMPTZ DEFAULT now()   -- [NOW-CANDIDATE] trailing+defaulted: prod omits
) RETURNS BIGINT AS $$
DECLARE
    v_c           central_minimal_invoices;
    v_existing_id BIGINT;
    v_pay_id      BIGINT;
BEGIN
    SELECT * INTO v_c FROM central_minimal_invoices WHERE invoice_id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'central has no record of invoice % (it was never intimated) — cannot record a payment for it.', p_invoice_id
            USING ERRCODE = 'ER053';
    END IF;

    IF v_c.tenant_id IS DISTINCT FROM p_tenant_id OR v_c.platform_code IS DISTINCT FROM p_platform_code THEN
        RAISE EXCEPTION 'central invoice % does not belong to tenant %/% — refusing to record a payment against another tenant''s invoice.',
            p_invoice_id, p_tenant_id, p_platform_code USING ERRCODE = 'ER067';
    END IF;

    -- idempotent replay of the same gateway txn -> return the existing payment, enqueue nothing new
    SELECT id INTO v_existing_id FROM central_payments
     WHERE gateway_code = p_gateway_code AND gateway_txn_ref = p_gateway_txn_ref;
    IF FOUND THEN
        RETURN v_existing_id;
    END IF;

    IF p_currency <> v_c.currency OR p_amount_minor <> v_c.amount_minor THEN
        RAISE EXCEPTION 'central payment (% %) does not match the recorded invoice total (% %).',
            p_amount_minor, p_currency, v_c.amount_minor, v_c.currency USING ERRCODE = 'ER057';
    END IF;
    IF v_c.status = 'paid' THEN
        RAISE EXCEPTION 'central invoice % is already paid — a second payment is refused.', p_invoice_id USING ERRCODE = 'ER055';
    END IF;

    INSERT INTO central_payments (invoice_id, gateway_code, gateway_txn_ref, amount_minor, currency, captured_at, created_at, created_by)
    VALUES (p_invoice_id, p_gateway_code, p_gateway_txn_ref, p_amount_minor, p_currency, p_captured_at, p_created_at, p_created_by)
    RETURNING id INTO v_pay_id;

    UPDATE central_minimal_invoices
       SET status = 'paid', paid_at = p_captured_at, gateway_txn_ref = p_gateway_txn_ref, applied_at = p_created_at
     WHERE invoice_id = p_invoice_id;

    -- ATOMIC reverse enqueue (mirror of the forward trigger): commits WITH the payment
    -- tenant_id/platform_code are carried in the reverse payload too (from
    -- central's own copy of them, applied by central_apply_intimation from
    -- the forward intimation) so product_apply_paid can enforce the SAME
    -- tenant-ownership check inv_record_payment now requires (ER067) — the
    -- reverse leg must not be able to settle the wrong tenant's invoice on
    -- the product side any more than a direct caller can.
    INSERT INTO inv_outbox (direction, invoice_id, event_type, payload, status,
                            attempts, next_attempt_at, created_at, created_by)
    VALUES ('to_product', p_invoice_id, 'invoice_paid',
            jsonb_build_object(
                'invoice_id',      p_invoice_id,
                'tenant_id',       v_c.tenant_id,
                'platform_code',   v_c.platform_code,
                'gateway_code',    p_gateway_code,
                'gateway_txn_ref', p_gateway_txn_ref,
                'amount_minor',    p_amount_minor,
                'currency',        p_currency,
                'captured_at',     p_captured_at),
            'pending', 0, p_created_at, p_created_at, p_created_by);

    RETURN v_pay_id;
END;
$$ LANGUAGE plpgsql;
