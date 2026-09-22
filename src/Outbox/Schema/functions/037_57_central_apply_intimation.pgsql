-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Outbox :: functions :: function central_apply_intimation — split from 037_invoice_outbox_intimation.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

-- central_apply_intimation(payload, at): the far-side handler. UPSERT keyed by
-- invoice_id, guarded by source_seq so a replay is a no-op. The payload envelope
-- carries 'seq' (the outbox event id) which the relay injects at delivery. Missing
-- required fields are rejected loudly (ER064) rather than persisting a half row.

CREATE OR REPLACE FUNCTION central_apply_intimation(p_payload JSONB, p_at TIMESTAMPTZ)
RETURNS BIGINT AS $$
DECLARE
    v_id  BIGINT;
    v_seq BIGINT;
    k     TEXT;
BEGIN
    FOREACH k IN ARRAY ARRAY['invoice_id','seq','invoice_number','tenant_id','platform_code',
                             'amount_minor','currency','status','billing_country_code'] LOOP
        IF NOT (p_payload ? k) OR p_payload->>k IS NULL THEN
            RAISE EXCEPTION 'central intimation payload is missing required field "%".', k USING ERRCODE = 'ER064';
        END IF;
    END LOOP;

    v_id  := (p_payload->>'invoice_id')::BIGINT;
    v_seq := (p_payload->>'seq')::BIGINT;

    INSERT INTO central_minimal_invoices (
        invoice_id, invoice_number, tenant_id, platform_code, amount_minor, currency,
        due_date, status, billing_country_code, gateway_override_code,
        source_seq, apply_count, applied_at, updated_by)
    VALUES (
        v_id,
        p_payload->>'invoice_number',
        (p_payload->>'tenant_id')::UUID,
        p_payload->>'platform_code',
        (p_payload->>'amount_minor')::BIGINT,
        p_payload->>'currency',
        (p_payload->>'due_date')::TIMESTAMPTZ,       -- NULL-safe (absent/json-null -> NULL)
        p_payload->>'status',
        p_payload->>'billing_country_code',
        p_payload->>'gateway_override_code',
        v_seq, 1, p_at, 'central-apply')
    ON CONFLICT (invoice_id) DO UPDATE SET
        invoice_number        = EXCLUDED.invoice_number,
        tenant_id             = EXCLUDED.tenant_id,
        platform_code         = EXCLUDED.platform_code,
        amount_minor          = EXCLUDED.amount_minor,
        currency              = EXCLUDED.currency,
        due_date              = EXCLUDED.due_date,
        status                = EXCLUDED.status,
        billing_country_code  = EXCLUDED.billing_country_code,
        gateway_override_code = EXCLUDED.gateway_override_code,
        source_seq            = EXCLUDED.source_seq,
        apply_count           = central_minimal_invoices.apply_count + 1,
        applied_at            = EXCLUDED.applied_at,
        updated_by            = EXCLUDED.updated_by
      WHERE EXCLUDED.source_seq > central_minimal_invoices.source_seq;  -- strictly-newer only => replay is a no-op

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;
