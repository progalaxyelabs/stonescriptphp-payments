-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Outbox :: functions :: trigger function inv_outbox_enqueue_on_intimation — split from 037_invoice_outbox_intimation.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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
-- 4. THE ATOMIC ENQUEUE TRIGGER  (non-invasive to 035)
-- =====================================================================
-- Chosen mechanism: an AFTER INSERT OR UPDATE trigger on inv_invoices, rather than
-- editing inv_issue_invoice (035). WHY a trigger: the enqueue then fires inside the
-- SAME transaction as EVERY path that puts an invoice into an intimated status —
-- the direct INSERT-as-issued path AND the draft->issued transition path — with no
-- edit to 035 and no way for a future caller to forget it. Because it runs in the
-- issuing transaction, the outbox row and the invoice commit or roll back together
-- (atomicity req 1). It stamps the row from NEW.issued_at (a timestamp already on
-- the row) so it introduces NO new now(). Only statuses present in
-- inv_outbox_intimation_statuses enqueue, and only on entry to that status
-- (INSERT, or an UPDATE that actually changed status) — so the paid/due UPDATEs
-- from 035 do NOT spuriously enqueue.

CREATE OR REPLACE FUNCTION inv_outbox_enqueue_on_intimation() RETURNS TRIGGER AS $$
DECLARE
    v_map inv_outbox_intimation_statuses;
BEGIN
    SELECT * INTO v_map FROM inv_outbox_intimation_statuses WHERE invoice_status = NEW.status;
    IF FOUND AND (TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status) THEN
        -- NEW.issued_at is the issue instant (035 sets it on both the INSERT-issued
        -- path and the draft->issued transition); it is the event = enqueue = ready
        -- instant. NOT NULL on the invoice row would fail loud if it were null.
        INSERT INTO inv_outbox (direction, invoice_id, event_type, payload, status,
                                attempts, next_attempt_at, created_at, created_by)
        VALUES (v_map.direction, NEW.id, v_map.event_type, inv_outbox_minimal_payload(NEW), 'pending',
                0, NEW.issued_at, NEW.issued_at, NEW.created_by);
    END IF;
    RETURN NULL;  -- AFTER trigger
END;
$$ LANGUAGE plpgsql;
