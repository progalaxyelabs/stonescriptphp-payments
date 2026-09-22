-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Invoicing :: functions :: inv_record_payment — split from 035_invoice_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: persisted-invoice FUNCTIONS — issue, guarded status
--   lifecycle, data-driven gateway routing, idempotent single-success payments,
--   the checkout/already-paid guard, and the CRM chase projections.
--
-- Every FORMULA is here; every VALUE it needs is a DATA row from 034 (gateways,
-- routing rules, the status set, the legal transitions). The only literals in
-- these bodies are enum/mode LABELS used as control tokens ('paid','success',
-- 'INR', ...) — structural identifiers exactly like the 'intrastate'/'no_tax'
-- mode tokens the tax engine (030) branches on, NOT business numbers. There is
-- not a single bare price / rate / duration / count constant in any body.
-- Integer paisa throughout. NO now()/CURRENT_DATE — see [NOW-CANDIDATE] tags.

-- =====================================================================
-- 4. RECORD A PAYMENT  (idempotent, single-success, due->paid exactly once)
-- =====================================================================
-- Records a payment against an invoice.
--  * A replay of the SAME (gateway, gateway_txn_ref) FOR THE SAME INVOICE
--    returns the existing payment id — true idempotency for webhook retries
--    (no double anything). The SAME (gateway, gateway_txn_ref) recorded
--    against a DIFFERENT invoice is never silently accepted as a match — see
--    ER066 below (fixed 2026-09-22: this table's unique index on
--    (gateway_code, gateway_txn_ref) is global, not per-invoice, so without
--    this check a mis-routed/replayed webhook for the WRONG invoice_id would
--    have returned another invoice's payment id while leaving the caller's
--    intended invoice untouched and unpaid — silently).
--  * A NEW successful payment against an already-paid invoice raises ER055.
--  * A success is only accepted when the invoice has a legal ->paid edge from
--    its current status (i.e. it is 'due'); otherwise ER056.
--  * amount+currency must equal the invoice's gross_total_minor+currency (ER057).
--  * A 'failed' payment is recorded (audit) and never transitions the invoice.
-- The partial unique index inv_payments_one_success_per_invoice is the ultimate
-- concurrency backstop: two racing successes cannot both persist.
-- p_captured_at is the GATEWAY's own capture time (a business input, not our now);
-- p_created_at is [NOW-CANDIDATE].
--
-- TENANT ISOLATION (ER067, added 2026-09-22): see inv_resolve_gateway's note
-- above. p_tenant_id/p_platform_code are REQUIRED — this is the ONE function
-- that mutates an invoice into 'paid', so it is the highest-value target for
-- a cross-tenant write (e.g. paying off tenant B's invoice from a session
-- authenticated as tenant A, or a mis-routed/replayed webhook attempting to
-- settle the wrong tenant's invoice). The check runs BEFORE any idempotent-
-- replay lookup or insert, on the SAME locked row already fetched.

CREATE OR REPLACE FUNCTION inv_record_payment(
    p_invoice_id     BIGINT,
    p_tenant_id      UUID,
    p_platform_code  VARCHAR(50),
    p_gateway_code   TEXT,
    p_gateway_txn_ref TEXT,
    p_amount_minor   BIGINT,
    p_currency       TEXT,
    p_status         TEXT,
    p_captured_at    TIMESTAMPTZ,   -- BUSINESS INPUT from the gateway (not a now-candidate)
    p_created_by     TEXT,
    p_created_at     TIMESTAMPTZ DEFAULT now()   -- [NOW-CANDIDATE] trailing+defaulted: prod omits
) RETURNS BIGINT AS $$
DECLARE
    v_inv             inv_invoices;
    v_existing_id     BIGINT;
    v_existing_invoice_id BIGINT;
    v_pay_id          BIGINT;
BEGIN
    IF p_status NOT IN ('success', 'failed') THEN
        RAISE EXCEPTION 'payment status "%" is invalid (expected ''success'' or ''failed'').', p_status USING ERRCODE = 'ER061';
    END IF;

    SELECT * INTO v_inv FROM inv_invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'invoice % does not exist', p_invoice_id USING ERRCODE = 'ER053';
    END IF;

    IF v_inv.tenant_id IS DISTINCT FROM p_tenant_id OR v_inv.platform_code IS DISTINCT FROM p_platform_code THEN
        RAISE EXCEPTION 'invoice % does not belong to tenant %/% — refusing to record a payment against another tenant''s invoice.',
            p_invoice_id, p_tenant_id, p_platform_code USING ERRCODE = 'ER067';
    END IF;

    -- idempotent replay: same gateway txn already recorded -> return it, do
    -- nothing else. gateway_txn_ref is unique GLOBALLY (across all invoices),
    -- so a match must be verified against THIS invoice_id before treating it
    -- as a same-invoice replay — a match for a different invoice is a real
    -- error (ER066), never a silent cross-invoice return.
    SELECT id, invoice_id INTO v_existing_id, v_existing_invoice_id FROM inv_payments
     WHERE gateway_code = p_gateway_code AND gateway_txn_ref = p_gateway_txn_ref;
    IF FOUND THEN
        IF v_existing_invoice_id <> p_invoice_id THEN
            RAISE EXCEPTION 'gateway % transaction % is already recorded against invoice %, not invoice % — refusing to silently misattribute it.',
                p_gateway_code, p_gateway_txn_ref, v_existing_invoice_id, p_invoice_id USING ERRCODE = 'ER066';
        END IF;
        RETURN v_existing_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM inv_gateways WHERE code = p_gateway_code AND is_active) THEN
        RAISE EXCEPTION 'gateway "%" is not a known active gateway.', p_gateway_code USING ERRCODE = 'ER058';
    END IF;

    IF p_currency <> v_inv.currency OR p_amount_minor <> v_inv.gross_total_minor THEN
        RAISE EXCEPTION 'payment (% %) does not match the invoice total (% %).',
            p_amount_minor, p_currency, v_inv.gross_total_minor, v_inv.currency USING ERRCODE = 'ER057';
    END IF;

    IF p_status = 'success' THEN
        IF v_inv.status = 'paid' THEN
            RAISE EXCEPTION 'invoice % is already paid — a second successful payment is refused (no double charge).', p_invoice_id
                USING ERRCODE = 'ER055';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM inv_invoice_status_transitions
                        WHERE from_status = v_inv.status AND to_status = 'paid') THEN
            RAISE EXCEPTION 'invoice % is not payable from status "%" (no legal edge to paid).', p_invoice_id, v_inv.status
                USING ERRCODE = 'ER056';
        END IF;

        INSERT INTO inv_payments (invoice_id, gateway_code, gateway_txn_ref, amount_minor, currency, status, captured_at, created_at, created_by)
        VALUES (p_invoice_id, p_gateway_code, p_gateway_txn_ref, p_amount_minor, p_currency, p_status, p_captured_at, p_created_at, p_created_by)
        RETURNING id INTO v_pay_id;

        -- the one and only due->paid transition; paid_at = the gateway's capture time
        UPDATE inv_invoices SET status = 'paid', paid_at = p_captured_at WHERE id = p_invoice_id;
    ELSE
        INSERT INTO inv_payments (invoice_id, gateway_code, gateway_txn_ref, amount_minor, currency, status, captured_at, created_at, created_by)
        VALUES (p_invoice_id, p_gateway_code, p_gateway_txn_ref, p_amount_minor, p_currency, p_status, p_captured_at, p_created_at, p_created_by)
        RETURNING id INTO v_pay_id;
    END IF;

    RETURN v_pay_id;
END;
$$ LANGUAGE plpgsql;
