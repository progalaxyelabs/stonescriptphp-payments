-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: pay_apply_capture
--
-- THE single path by which a gateway capture takes effect. The webhook processor, the admin
-- "apply this payment" path and any reconciliation job all call this one function, so there is
-- one place to get exactly-once right instead of one per platform.
--
-- One transaction, in this order:
--   1. take an advisory lock on (gateway, transaction): racing deliveries of the SAME capture
--      queue up behind the first, then find it recorded
--   2. resolve the order from the library's own order_ref (never from an e-mail address or a
--      guess). No order_ref, or an unknown one => outcome 'unattributed', NOTHING written
--   3. lock the order row; a capture already recorded for this (gateway, transaction) => 'already_applied' (or
--      'captured_not_applied' if its order is not paid) with the original ids, no second effect. The SAME transaction
--      re-reported against another order or with another amount raises PY033 (integrity violation; the original money
--      is already accounted for, so nothing is queued for refund)
--   4. a NEW transaction whose tenant, platform, gateway, mode, amount or currency differs from the order is not raised
--      away: it is queued in pay_refund_queue (reason 'review_mismatch') and returns 'refund_required'. An order
--      reference we issued that matches no order is queued as 'unattributed' (and returns 'unattributed'). Real money must
--      never live only in the webhook inbox, which is a retention-limited log. A capture of an already-paid or cancelled
--      order is likewise queued, not applied twice
--   5. record the capture (pay_record_captured_payment, the idempotent primitive)
--   6. apply the purpose, all in this same transaction:
--        invoice_payment      record the payment against the existing invoice (-> paid)
--        subscription_period  issue the invoice from the order's spec and series, mark it paid,
--                             renew the subscription (stacks remaining time)
--        one_time_license     issue + pay the invoice, enrol the one-time plan
--        wallet_topup         issue + pay the invoice, credit the wallet grant
--      The invoice must total exactly the order amount (PY034), re-proved here.
--   7. mark the order paid and append payment.applied (+ entitlement.changed / wallet.credited)
--      to pay_events
-- If anything raises, the whole transaction rolls back: no invoice, no number, no payment, no
-- entitlement, no event. The caller marks the webhook inbox row failed and alerts.
--
-- MONEY THAT CANNOT BE APPLIED is never absorbed and never raised away: a mismatching capture (see 4), a capture for an order that is already paid
-- or cancelled, or for an invoice that was voided or paid meanwhile, rolls the attempted application back and writes a
-- pay_refund_queue entry (committed, visible), then returns outcome 'refund_required' (the PHP processor fails the inbox
-- row, which alerts). A capture row that exists while its order is NOT paid (a half-applied state that only a direct
-- call of the capture primitive could create) returns 'captured_not_applied' - distinct from 'already_applied', and also
-- alerted - so a redelivery can never hide an unfulfilled payment.
--
-- FINANCIAL YEAR / DOCUMENT DATE: the invoice is dated, hence numbered into the FY of, the ISSUE MOMENT (p_issued_at,
-- default now()), NOT of captured_at. A late or admin-applied capture of a payment received on 31 March but applied on
-- 2 April is invoiced in the new FY with the next number of that FY: a number is never issued out of order across
-- 1 April. (GST time-of-supply for an advance is the earlier of invoice date and payment receipt - CGST s.13(2); that
-- tax consequence is for the CA to confirm. The gateway's capture time is still stored as the payment's paid_at.)
-- The document date must lie within issue_date_window_days of now() (PY042).
--
-- p_raw is passed through _pay_capture_raw_allowlist() before storage: only allow-listed, format-checked fields survive.
-- p_tenant_id / p_platform_code are the identity the gateway echoed back (nullable): when given
-- they must equal the order's. p_mode is derived from the gateway key by the caller.
-- Returns o_outcome in ('applied', 'already_applied', 'unattributed', 'captured_not_applied', 'refund_required').
CREATE OR REPLACE FUNCTION pay_apply_capture(
    p_gateway_code    TEXT,
    p_gateway_txn_ref TEXT,
    p_order_ref       TEXT,
    p_tenant_id       UUID,
    p_platform_code   VARCHAR(50),
    p_amount_minor    BIGINT,
    p_currency        TEXT,
    p_mode            TEXT,
    p_captured_at     TIMESTAMPTZ,
    p_source          TEXT,
    p_raw             TEXT DEFAULT NULL,
    p_issued_at       TIMESTAMPTZ DEFAULT NULL
) RETURNS TABLE (
    o_outcome TEXT, o_order_ref TEXT, o_order_id BIGINT, o_purpose TEXT,
    o_invoice_id BIGINT, o_payment_id BIGINT, o_detail TEXT
) AS $$
DECLARE
    v_order    pay_orders;
    v_prev     pay_captured_payments;
    v_cap      RECORD;
    v_quote    RECORD;
    v_spec     JSONB;
    v_invoice  BIGINT;
    v_pay      BIGINT;
    v_taxable  BIGINT;
    v_cpp      BIGINT;
    v_ot       one_time_pricing_plans;
    v_wt       RECORD;
    v_sub      RECORD;
    v_ap       RECORD;
    v_int      INTERVAL;
    v_product  TEXT;
    v_issued   TIMESTAMPTZ := coalesce(p_issued_at, now());
    v_reason   TEXT;
    v_detail   TEXT;
BEGIN
    PERFORM _inv_assert_schema_current();
    IF p_gateway_code IS NULL OR btrim(p_gateway_code) = '' OR p_gateway_txn_ref IS NULL OR btrim(p_gateway_txn_ref) = ''
       OR p_captured_at IS NULL OR p_source IS NULL OR btrim(p_source) = '' THEN
        RAISE EXCEPTION 'pay_apply_capture: gateway, transaction reference, capture time and source are required.'
            USING ERRCODE = 'PY030';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(p_gateway_code || ':' || p_gateway_txn_ref, 0));

    IF p_order_ref IS NULL OR btrim(p_order_ref) = '' THEN
        o_outcome := 'unattributed'; o_detail := 'the capture carries no order reference';
        RETURN NEXT; RETURN;
    END IF;
    SELECT * INTO v_order FROM pay_orders WHERE order_ref = p_order_ref FOR UPDATE;
    IF NOT FOUND THEN
        -- our order reference, but no such order: real money with nowhere to go. Queue it (idempotent), still 'unattributed'.
        IF NOT EXISTS (SELECT 1 FROM pay_captured_payments WHERE gateway_code = p_gateway_code AND gateway_txn_ref = p_gateway_txn_ref) THEN
            PERFORM _pay_queue_refund(p_gateway_code, p_gateway_txn_ref, p_order_ref, p_tenant_id, p_platform_code,
                                      p_amount_minor, p_currency, 'unattributed', 'no order ' || p_order_ref || ' exists');
        END IF;
        o_outcome := 'unattributed'; o_order_ref := p_order_ref; o_detail := 'no such order';
        RETURN NEXT; RETURN;
    END IF;

    -- the same capture again: report the original outcome, apply nothing. (Checked BEFORE the mismatch tests: money that was
    -- already recorded is accounted for once, and a redelivery must never queue it for refund.)
    SELECT * INTO v_prev FROM pay_captured_payments WHERE gateway_code = p_gateway_code AND gateway_txn_ref = p_gateway_txn_ref;
    IF FOUND THEN
        IF v_prev.reference IS DISTINCT FROM p_order_ref THEN
            RAISE EXCEPTION 'gateway % transaction % was recorded for order %, not %: refusing to misattribute it.',
                p_gateway_code, p_gateway_txn_ref, v_prev.reference, p_order_ref USING ERRCODE = 'PY033';
        END IF;
        IF v_prev.amount_minor IS DISTINCT FROM p_amount_minor OR v_prev.currency IS DISTINCT FROM p_currency THEN
            RAISE EXCEPTION 'gateway % transaction % was recorded as % %, now reported as % %.',
                p_gateway_code, p_gateway_txn_ref, v_prev.amount_minor, v_prev.currency, p_amount_minor, p_currency
                USING ERRCODE = 'PY033';
        END IF;
        o_order_ref := v_order.order_ref; o_order_id := v_order.id; o_purpose := v_order.purpose;
        o_invoice_id := v_order.invoice_id; o_payment_id := v_order.payment_id;
        IF v_order.status = 'paid' THEN
            o_outcome := 'already_applied';
        ELSE
            -- the payment is recorded but its order never took effect: do NOT report it as applied
            o_outcome := 'captured_not_applied';
            o_detail := 'the capture is recorded but order ' || v_order.order_ref || ' is ' || v_order.status || ': nothing was fulfilled';
        END IF;
        RETURN NEXT; RETURN;
    END IF;

    -- A NEW transaction that disagrees with the order it names is real money too. It is queued for a human (reason
    -- 'review_mismatch'), never raised away: a raise would leave it only in the retention-limited webhook inbox.
    IF (p_platform_code IS NOT NULL AND p_platform_code IS DISTINCT FROM v_order.platform_code)
       OR (p_tenant_id IS NOT NULL AND p_tenant_id IS DISTINCT FROM v_order.tenant_id) THEN
        v_reason := 'review_mismatch';
        v_detail := 'capture names tenant/platform ' || coalesce(p_tenant_id::text, '-') || '/' || coalesce(p_platform_code, '-')
                    || ' but order ' || p_order_ref || ' belongs to another tenant/platform';
    ELSIF v_order.gateway_code IS DISTINCT FROM p_gateway_code THEN
        v_reason := 'review_mismatch';
        v_detail := 'order ' || p_order_ref || ' is a ' || v_order.gateway_code || ' order but the capture arrived from ' || p_gateway_code;
    ELSIF p_mode IS NULL OR p_mode IS DISTINCT FROM v_order.mode THEN
        v_reason := 'review_mismatch';
        v_detail := 'order ' || p_order_ref || ' is a ' || v_order.mode || ' order but the capture is in mode ' || coalesce(p_mode, '(unknown)');
    ELSIF p_amount_minor IS DISTINCT FROM v_order.amount_minor OR p_currency IS DISTINCT FROM v_order.currency THEN
        v_reason := 'review_mismatch';
        v_detail := 'capture of ' || coalesce(p_amount_minor::text, '?') || ' ' || coalesce(p_currency, '?') || ' does not match order '
                    || p_order_ref || ' (' || v_order.amount_minor || ' ' || v_order.currency || ')';
    END IF;

    -- money that arrived for an order nothing can fulfil: roll nothing in, record it where a human sees it
    IF v_reason IS NOT NULL THEN
        NULL;   -- a mismatch decided above
    ELSIF v_order.status NOT IN ('created', 'open') THEN
        v_reason := 'order_not_open';
        v_detail := 'order ' || p_order_ref || ' is ' || v_order.status;
    ELSE
        BEGIN
            SELECT * INTO v_cap FROM pay_record_captured_payment(
                p_gateway_code, p_gateway_txn_ref, p_order_ref, p_amount_minor, p_currency, 'success', p_captured_at, p_source, _pay_capture_raw_allowlist(p_raw));
            IF v_cap.o_already_applied THEN
                o_outcome := 'captured_not_applied'; o_order_ref := v_order.order_ref; o_order_id := v_order.id; o_purpose := v_order.purpose;
                o_invoice_id := v_order.invoice_id; o_payment_id := v_order.payment_id;
                o_detail := 'the capture was recorded concurrently but its order is not paid';
                RETURN NEXT; RETURN;
            END IF;

            IF v_order.purpose = 'invoice_payment' THEN
                v_invoice := v_order.invoice_id;
                v_pay := inv_record_payment(v_invoice, v_order.tenant_id, v_order.platform_code, p_gateway_code, p_gateway_txn_ref,
                                            p_amount_minor, p_currency, 'success', p_captured_at, p_source);
            ELSE
                v_spec := v_order.invoice_spec;
                SELECT * INTO v_quote FROM _pay_order_quote(v_order.series_code, v_spec, v_order.currency, v_issued);
                IF v_quote.o_gross_minor IS DISTINCT FROM v_order.amount_minor THEN
                    RAISE EXCEPTION 'order %: the invoice now totals % but the order is for %.', p_order_ref, v_quote.o_gross_minor, v_order.amount_minor
                        USING ERRCODE = 'PY034';
                END IF;

                v_invoice := inv_issue_invoice(
                    NULL, v_order.tenant_id, v_order.platform_code, v_order.purpose, v_order.order_ref,
                    v_issued, NULL, v_issued + make_interval(days => coalesce((v_spec->>'due_days')::int, 0)),
                    v_spec->>'billing_country_code', v_spec->>'billing_state',
                    NULL, _pay_order_spec_buyer(v_spec),
                    coalesce(v_spec->>'supply_type', 'domestic'), v_spec->>'document_type',
                    coalesce((v_spec->>'price_is_inclusive')::boolean, false), coalesce((v_spec->>'round_off')::boolean, false),
                    v_order.currency, v_spec->>'fx_rate', v_spec->>'amount_inr',
                    v_issued, _pay_order_spec_lines(v_spec),
                    v_order.gateway_code, p_source, now(), 'issued', v_order.series_code, v_order.mode);

                -- issued -> due -> paid: the payment is recorded against a payable invoice, as everywhere else
                PERFORM inv_transition_invoice_status(v_invoice, v_order.tenant_id, v_order.platform_code, 'due', p_source, v_issued);
                v_pay := inv_record_payment(v_invoice, v_order.tenant_id, v_order.platform_code, p_gateway_code, p_gateway_txn_ref,
                                            p_amount_minor, p_currency, 'success', p_captured_at, p_source);

                v_product := coalesce(v_spec->>'product', 'default');
                IF v_order.purpose = 'subscription_period' THEN
                    SELECT * INTO v_sub FROM renew_subscription_pricing_plan(
                        v_order.tenant_id, v_order.platform_code, v_order.catalog_ref::bigint, p_captured_at, p_source);
                    -- the ONE entitlement store: the period stacks onto remaining time and is audited against this order
                    SELECT (spp.duration || ' ' || spp.duration_uom)::interval INTO v_int FROM subscription_pricing_plans spp WHERE spp.id = v_order.catalog_ref::bigint;
                    SELECT * INTO v_ap FROM _ent_apply_period(v_order.tenant_id, v_order.platform_code, v_product, 'payment', 'sub:' || v_order.catalog_ref,
                        v_order.catalog_ref::bigint, v_int, 'active', 'payment', p_captured_at, 'pay:' || v_order.order_ref,
                        encode(sha256(convert_to(concat_ws('|', 'payment', v_order.order_ref, v_order.catalog_ref), 'UTF8')), 'hex'), p_source, 'payment', v_invoice, v_pay);
                    INSERT INTO pay_events (event_type, tenant_id, platform_code, order_ref, payload)
                    VALUES ('entitlement.changed', v_order.tenant_id, v_order.platform_code, v_order.order_ref,
                            jsonb_build_object('kind', 'subscription_period', 'mode', v_order.mode, 'customer_pricing_plan_id', v_sub.customer_pricing_plan_id,
                                               'subscription_pricing_plan_id', v_sub.subscription_pricing_plan_id,
                                               'started_at', v_sub.started_at, 'expires_at', v_sub.expires_at,
                                               'product', v_product, 'entitlement_period_end', v_ap.o_period_to));
                ELSIF v_order.purpose = 'one_time_license' THEN
                    SELECT * INTO v_ot FROM one_time_pricing_plans WHERE id = v_order.catalog_ref::bigint;
                    INSERT INTO customer_pricing_plans (tenant_id, platform_code, pricing_plan_id, one_time_pricing_plan_id, started_at, created_at, created_by)
                    VALUES (v_order.tenant_id, v_order.platform_code, v_ot.pricing_plan_id, v_ot.id, p_captured_at, p_captured_at, p_source)
                    RETURNING id INTO v_cpp;
                    SELECT * INTO v_ap FROM _ent_apply_period(v_order.tenant_id, v_order.platform_code, v_product, 'payment', 'otl:' || v_ot.id, NULL, NULL,
                        'active', 'payment', p_captured_at, 'pay:' || v_order.order_ref,
                        encode(sha256(convert_to(concat_ws('|', 'payment', v_order.order_ref, v_order.catalog_ref), 'UTF8')), 'hex'), p_source, 'payment', v_invoice, v_pay);
                    INSERT INTO pay_events (event_type, tenant_id, platform_code, order_ref, payload)
                    VALUES ('entitlement.changed', v_order.tenant_id, v_order.platform_code, v_order.order_ref,
                            jsonb_build_object('kind', 'one_time_license', 'mode', v_order.mode, 'customer_pricing_plan_id', v_cpp,
                                               'one_time_pricing_plan_id', v_ot.id, 'started_at', p_captured_at, 'product', v_product));
                ELSIF v_order.purpose = 'wallet_topup' THEN
                    SELECT taxable_value_minor INTO v_taxable FROM inv_invoices WHERE id = v_invoice;
                    -- wallet v2: the credit is bound to THIS capture (key cap:<gateway>:<txn>), in milli-credits
                    SELECT * INTO v_wt FROM _wlt_topup(v_order.tenant_id, v_order.platform_code, v_order.catalog_ref::bigint, v_taxable,
                                                       p_gateway_code, p_gateway_txn_ref, p_captured_at, p_source);
                    INSERT INTO pay_events (event_type, tenant_id, platform_code, order_ref, payload)
                    VALUES ('wallet.credited', v_order.tenant_id, v_order.platform_code, v_order.order_ref,
                            jsonb_build_object('mode', v_order.mode, 'grant_id', v_wt.o_grant_id, 'wallet_id', v_wt.o_wallet_id,
                                               'granted_milli', v_wt.o_granted_milli,
                                               'granted_credits', v_wt.o_granted_milli::numeric / _pay_config_int('wallet_milli_per_credit'),
                                               'amount_paid_minor', v_taxable, 'expires_at', v_wt.o_expires_at));
                END IF;
            END IF;

            UPDATE pay_orders SET status = 'paid', paid_at = p_captured_at, invoice_id = v_invoice, payment_id = v_pay,
                                  captured_payment_id = v_cap.o_payment_id
             WHERE id = v_order.id;

            INSERT INTO pay_events (event_type, tenant_id, platform_code, order_ref, payload)
            VALUES ('payment.applied', v_order.tenant_id, v_order.platform_code, v_order.order_ref,
                    jsonb_build_object('purpose', v_order.purpose, 'invoice_id', v_invoice, 'payment_id', v_pay,
                                       'gateway', p_gateway_code, 'gateway_txn_ref', p_gateway_txn_ref,
                                       'amount_minor', p_amount_minor, 'currency', p_currency, 'mode', v_order.mode, 'source', p_source));

            o_outcome := 'applied'; o_order_ref := v_order.order_ref; o_order_id := v_order.id; o_purpose := v_order.purpose;
            o_invoice_id := v_invoice; o_payment_id := v_pay;
            RETURN NEXT; RETURN;
        EXCEPTION
            WHEN SQLSTATE 'ER055' THEN
                v_reason := 'invoice_already_paid'; v_detail := SQLERRM;
            WHEN SQLSTATE 'ER056' THEN
                v_reason := 'invoice_not_payable'; v_detail := SQLERRM;
            WHEN SQLSTATE 'PY061' THEN
                v_reason := 'entitlement_conflict'; v_detail := SQLERRM;
            WHEN SQLSTATE 'PY066' THEN
                v_reason := 'paid_while_suspended'; v_detail := SQLERRM;
            WHEN SQLSTATE 'ER013' OR SQLSTATE 'ER014' OR SQLSTATE 'ER015' OR SQLSTATE 'PY070' OR SQLSTATE 'PY071' THEN
                -- a paid wallet top-up that cannot be fulfilled (pack gone or inactive, no credit, key clash): never lost, never silent
                v_reason := 'wallet_unfulfillable'; v_detail := SQLERRM;
        END;
        -- reached only through the handlers above: everything the block did has been rolled back
    END IF;

    PERFORM _pay_queue_refund(p_gateway_code, p_gateway_txn_ref, v_order.order_ref, v_order.tenant_id, v_order.platform_code,
                              p_amount_minor, p_currency, v_reason, v_detail);
    o_outcome := 'refund_required'; o_order_ref := v_order.order_ref; o_order_id := v_order.id; o_purpose := v_order.purpose;
    o_invoice_id := NULL; o_payment_id := NULL; o_detail := v_reason || ': ' || v_detail;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
