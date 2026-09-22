-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Invoicing :: seeders :: inv_invoice_status_transitions — split from 034_invoice_persistence_tables.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: PERSISTED invoices + payments + gateway routing (DATA) +
--   status lifecycle set (DATA) + the CRM chase minimal-subset view.
--
-- This is the persistence layer that sits ON TOP of the pure GST tax-computation
-- engine (024-033). inv_compute_invoice() stays a pure calculator (STABLE, no
-- rows); inv_issue_invoice() (035) calls it and FREEZES the result into the
-- tables below. The charge side (subscription 022, wallet/overage 017/023,
-- passthrough 019, consumption 015/016) produces the amount; the GST engine adds
-- tax; this layer records the issued document, its payments, and how it settles.
--
-- ECOSYSTEM LAW honoured: every business VALUE is a DATA row, never a literal in
-- a function body — the gateways, the country->gateway routing rules, each
-- gateway's checkout endpoint, the legal status set, and the legal status
-- transitions are ALL rows here (035's functions carry only the FORMULA). Money
-- is INTEGER PAISA everywhere (024 law) — we deliberately DIVERGE from a reference
-- numeric(14,2) invoices.pgsql shape on TYPE while ALIGNING on shape/columns, because
-- the whole prototype is paisa-exact and never touches a float.
--
-- NO now()/CURRENT_DATE anywhere: every timestamp is an explicit caller param.
-- The "as-of-now" candidates for a later step-2 now() substitution are TAGGED
-- inline with the marker  [NOW-CANDIDATE]  (created_at columns and the state-
-- transition timestamps). Genuine business dates (issue_date, due_date, billing
-- period, a gateway's own captured_at) are NOT now-candidates and are so tagged.
--
-- New custom SQLSTATEs, continuing the ERxxx scheme (max in use before this file
-- was ER051; the spec's "after ER021" predates the 024-051 GST port):
--   ER052  no gateway route resolvable for the invoice's billing country   -> 400
--   ER053  invoice not found                                               -> 404
--   ER054  illegal invoice status transition                               -> 409
--   ER055  payment recorded against an already-paid invoice (dup guard)    -> 409
--   ER056  invoice is not payable from its current status                  -> 409
--   ER057  payment amount/currency does not match the invoice              -> 400
--   ER058  unknown or inactive gateway (override target or payment rail)   -> 400
--   ER059  invalid invoice status value (not a modelled status)            -> 400
--   ER060  billing_country_code is required and must be a 2-letter code    -> 400
--   ER061  invalid payment status value (expected 'success' | 'failed')    -> 400

INSERT INTO inv_invoice_status_transitions (from_status, to_status, note) VALUES
    ('draft',  'issued',    'Issue the drafted invoice.'),
    ('draft',  'cancelled', 'Abandon a draft before issue.'),
    ('issued', 'due',       'Due date reached — becomes payable.'),
    ('issued', 'void',      'Void an issued invoice (correction).'),
    ('due',    'paid',      'Settled by a successful payment (ONLY via inv_record_payment).'),
    ('due',    'void',      'Void a due invoice (correction).');
-- Deliberately ABSENT edges (each an ER054 if attempted): due->issued (no
-- un-souring), paid->anything (terminal), void/cancelled->anything, and any
-- direct issued->paid (payment requires the invoice be 'due' first — to allow
-- early payment, add an ('issued','paid') row here, no code change).
