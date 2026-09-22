-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Outbox :: functions :: one-time idempotent backfill INSERT (raw SQL, ON CONFLICT DO NOTHING — deployed via the functions-bucket batch_execute fallback, see report) — split from 037_invoice_outbox_intimation.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

-- BACKFILL: this outbox went live AFTER earlier files already issued invoices
-- (their INSERTs predate the trigger). The durable guarantee "no issued invoice
-- without an outbox row" must hold for the WHOLE set, so we backfill one pending
-- to_central row for every already-issued invoice that lacks one — exactly what a
-- real deployment runs once when the outbox is switched on. Timestamp = each
-- invoice's own issued_at (no now()). ON CONFLICT DO NOTHING makes it re-runnable.

INSERT INTO inv_outbox (direction, invoice_id, event_type, payload, status,
                        attempts, next_attempt_at, created_at, created_by)
SELECT 'to_central', i.id, 'invoice_issued', inv_outbox_minimal_payload(i), 'pending',
       0, i.issued_at, i.issued_at, 'outbox-backfill'
  FROM inv_invoices i
 WHERE i.issued_at IS NOT NULL
ON CONFLICT (invoice_id, direction, event_type) DO NOTHING;
