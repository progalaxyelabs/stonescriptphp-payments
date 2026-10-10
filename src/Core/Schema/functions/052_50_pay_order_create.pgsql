-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: pay_order_create
--
-- Creates a payment order idempotently and validates it up front, so money is never collected
-- for something that cannot be fulfilled or invoiced.
--
--   * Same (tenant, platform, idempotency_key) and the SAME request: returns the existing order
--     (o_is_new = false) - a client retry makes one order. A DIFFERENT request under the same
--     key is refused (PY036): the key names one request, not one customer.
--   * invoice_payment: the invoice must exist, belong to the tenant, be payable, match the
--     amount and currency, and be of the order's mode (a test invoice is never paid in live mode).
--   * Capture-first purposes: the catalog item must be sellable; the series must be an active
--     invoice series of the order's mode whose issuer is real for a live order; and the invoice
--     the spec produces must total exactly amount_minor (PY034) - the amount is quoted by the
--     server and re-proved here, never taken on trust.
--   * mode and gateway are the caller's server-side facts (derived from the gateway key), never
--     client input.
-- Returns the order and whether this call created it. The gateway order is attached afterwards
-- (pay_order_attach_gateway_order).
CREATE OR REPLACE FUNCTION pay_order_create(
    p_tenant_id       UUID,
    p_platform_code   VARCHAR(50),
    p_idempotency_key TEXT,
    p_purpose         TEXT,
    p_catalog_ref     TEXT,
    p_invoice_id      BIGINT,
    p_amount_minor    BIGINT,
    p_currency        TEXT,
    p_gateway_code    TEXT,
    p_mode            TEXT,
    p_series_code     TEXT,
    p_invoice_spec    TEXT,
    p_actor           TEXT
) RETURNS TABLE (
    o_order_ref TEXT, o_is_new BOOLEAN, o_status TEXT, o_gateway_order_id TEXT,
    o_amount_minor BIGINT, o_currency TEXT, o_gateway_code TEXT, o_mode TEXT, o_purpose TEXT
) AS $$
DECLARE
    v_spec   JSONB := p_invoice_spec::jsonb;
    v_hash   TEXT;
    v_row    pay_orders;
    v_series inv_series;
    v_issuer inv_issuers;
    v_pay    RECORD;
    v_inv    inv_invoices;
    v_ref    TEXT;
    v_quote  RECORD;
BEGIN
    PERFORM _inv_assert_schema_current();
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR btrim(p_platform_code) = '' THEN
        RAISE EXCEPTION 'tenant_id and platform_code are required' USING ERRCODE = 'ER001';
    END IF;
    IF p_actor IS NULL OR btrim(p_actor) = '' THEN
        RAISE EXCEPTION 'pay_order_create: actor is required.' USING ERRCODE = 'PY030';
    END IF;
    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN
        RAISE EXCEPTION 'pay_order_create: an idempotency key is required.' USING ERRCODE = 'PY030';
    END IF;

    v_hash := encode(sha256(convert_to(concat_ws('|', p_purpose, coalesce(p_catalog_ref, ''), coalesce(p_invoice_id::text, ''),
        p_amount_minor::text, p_currency, p_gateway_code, p_mode, coalesce(p_series_code, ''), coalesce(v_spec::text, '')), 'UTF8')), 'hex');

    -- replay: same key, same request => same order
    SELECT * INTO v_row FROM pay_orders
     WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code AND idempotency_key = p_idempotency_key;
    IF FOUND THEN
        IF v_row.request_hash <> v_hash THEN
            RAISE EXCEPTION 'idempotency key "%" was already used for a different order request.', p_idempotency_key
                USING ERRCODE = 'PY036';
        END IF;
        o_order_ref := v_row.order_ref; o_is_new := FALSE; o_status := v_row.status; o_gateway_order_id := v_row.gateway_order_id;
        o_amount_minor := v_row.amount_minor; o_currency := v_row.currency; o_gateway_code := v_row.gateway_code;
        o_mode := v_row.mode; o_purpose := v_row.purpose;
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_mode IS NULL OR p_mode NOT IN ('live', 'test') THEN
        RAISE EXCEPTION 'pay_order_create: mode must be ''live'' or ''test'' (got "%"); it is never assumed.', p_mode USING ERRCODE = 'PY012';
    END IF;
    IF p_amount_minor IS NULL OR p_amount_minor <= 0 THEN
        RAISE EXCEPTION 'pay_order_create: amount must be a positive number of minor units.' USING ERRCODE = 'PY030';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM inv_gateways WHERE code = p_gateway_code AND is_active) THEN
        RAISE EXCEPTION 'gateway "%" is not a known active gateway.', p_gateway_code USING ERRCODE = 'ER058';
    END IF;

    IF p_purpose = 'invoice_payment' THEN
        IF p_invoice_id IS NULL OR p_series_code IS NOT NULL OR v_spec IS NOT NULL OR p_catalog_ref IS NOT NULL THEN
            RAISE EXCEPTION 'an invoice_payment order names an existing invoice and nothing else (no catalog item, series or spec).'
                USING ERRCODE = 'PY030';
        END IF;
        SELECT * INTO v_pay FROM inv_invoice_payability(p_invoice_id, p_tenant_id, p_platform_code);
        IF NOT v_pay.is_payable THEN
            RAISE EXCEPTION 'invoice % is not payable (%).', p_invoice_id, v_pay.reason USING ERRCODE = 'PY030';
        END IF;
        IF v_pay.gross_total_minor <> p_amount_minor OR v_pay.currency <> p_currency THEN
            RAISE EXCEPTION 'order amount % % does not match the invoice total % %.',
                p_amount_minor, p_currency, v_pay.gross_total_minor, v_pay.currency USING ERRCODE = 'PY030';
        END IF;
        SELECT * INTO v_inv FROM inv_invoices WHERE id = p_invoice_id;
        -- a legacy invoice has mode NULL, which means LIVE: a test-mode order can never settle it
        IF coalesce(v_inv.mode, 'live') <> p_mode THEN
            RAISE EXCEPTION 'invoice % is a % invoice and cannot be paid through a % order.', p_invoice_id, coalesce(v_inv.mode, 'live'), p_mode
                USING ERRCODE = 'PY012';
        END IF;
    ELSIF p_purpose IN ('subscription_period', 'one_time_license', 'wallet_topup') THEN
        IF p_invoice_id IS NOT NULL OR p_catalog_ref IS NULL OR p_series_code IS NULL OR v_spec IS NULL THEN
            RAISE EXCEPTION 'a % order needs a catalog item, a numbering series and an invoice spec (and no existing invoice).', p_purpose
                USING ERRCODE = 'PY030';
        END IF;
        IF p_purpose IN ('subscription_period', 'one_time_license') AND EXISTS (
               SELECT 1 FROM ent_entitlements e WHERE e.tenant_id = p_tenant_id AND e.platform_code = p_platform_code
                  AND e.product = coalesce(v_spec->>'product', 'default') AND e.billing_mode = 'postpaid') THEN
            RAISE EXCEPTION 'this tenant is on a postpaid plan: it pays its invoices (invoice_payment), it does not buy a % order. An operator can switch it to prepaid first.', p_purpose
                USING ERRCODE = 'PY061';
        END IF;
        IF p_catalog_ref !~ '^[0-9]+$' THEN
            RAISE EXCEPTION 'catalog_ref "%" must be a plan id.', p_catalog_ref USING ERRCODE = 'PY030';
        END IF;
        IF p_purpose = 'subscription_period' AND NOT EXISTS (
               SELECT 1 FROM subscription_pricing_plans s JOIN pricing_plans p ON p.id = s.pricing_plan_id
                WHERE s.id = p_catalog_ref::bigint AND s.is_active AND p.is_active AND NOT p.is_trial) THEN
            RAISE EXCEPTION 'subscription plan % is not currently sellable.', p_catalog_ref USING ERRCODE = 'PY030';
        ELSIF p_purpose = 'one_time_license' AND NOT EXISTS (
               SELECT 1 FROM one_time_pricing_plans o JOIN pricing_plans p ON p.id = o.pricing_plan_id
                WHERE o.id = p_catalog_ref::bigint AND o.is_active AND p.is_active AND NOT p.is_trial) THEN
            RAISE EXCEPTION 'one-time plan % is not currently sellable.', p_catalog_ref USING ERRCODE = 'PY030';
        ELSIF p_purpose = 'wallet_topup' AND NOT EXISTS (
               SELECT 1 FROM wlt_packs w JOIN pricing_plans p ON p.id = w.pricing_plan_id
                WHERE w.id = p_catalog_ref::bigint AND w.is_active AND p.is_active AND w.credits_milli > 0) THEN
            RAISE EXCEPTION 'wallet pack % is not currently sellable (inactive, its plan inactive, or it grants no credit).', p_catalog_ref USING ERRCODE = 'PY030';
        END IF;

        SELECT * INTO v_series FROM inv_series WHERE series_code = p_series_code;
        IF NOT FOUND OR NOT v_series.is_active OR v_series.kind <> 'invoice' THEN
            RAISE EXCEPTION 'series "%" is not an active invoice series.', p_series_code USING ERRCODE = 'PY011';
        END IF;
        IF v_series.mode <> p_mode THEN
            RAISE EXCEPTION 'series "%" is a % series but the order is in % mode.', p_series_code, v_series.mode, p_mode USING ERRCODE = 'PY012';
        END IF;
        SELECT * INTO v_issuer FROM inv_issuers WHERE id = v_series.issuer_id;
        IF v_issuer.platform_code IS DISTINCT FROM p_platform_code
           OR (v_issuer.tenant_id IS NOT NULL AND v_issuer.tenant_id IS DISTINCT FROM p_tenant_id) THEN
            RAISE EXCEPTION 'series "%" is not available to this tenant and platform.', p_series_code USING ERRCODE = 'PY011';
        END IF;
        IF v_series.mode = 'live' AND v_issuer.is_placeholder THEN
            RAISE EXCEPTION 'no live order: issuer "%" of series "%" is still a placeholder, so the invoice could not be issued.',
                v_issuer.issuer_code, p_series_code USING ERRCODE = 'PY013';
        END IF;

        SELECT * INTO v_quote FROM _pay_order_quote(p_series_code, v_spec, p_currency, now());
        IF v_quote.o_gross_minor <> p_amount_minor THEN
            RAISE EXCEPTION 'quoted amount % does not match the invoice the spec produces (%).', p_amount_minor, v_quote.o_gross_minor
                USING ERRCODE = 'PY034';
        END IF;
    ELSE
        RAISE EXCEPTION 'purpose "%" is not one of subscription_period, one_time_license, wallet_topup, invoice_payment.', p_purpose
            USING ERRCODE = 'PY030';
    END IF;

    v_ref := 'ord_' || replace(gen_random_uuid()::text, '-', '');
    INSERT INTO pay_orders (order_ref, tenant_id, platform_code, idempotency_key, request_hash, purpose, catalog_ref, invoice_id,
                            amount_minor, currency, gateway_code, mode, series_code, invoice_spec, created_by)
    VALUES (v_ref, p_tenant_id, p_platform_code, p_idempotency_key, v_hash, p_purpose, p_catalog_ref, p_invoice_id,
            p_amount_minor, p_currency, p_gateway_code, p_mode, p_series_code, v_spec, p_actor)
    ON CONFLICT (tenant_id, platform_code, idempotency_key) DO NOTHING
    RETURNING * INTO v_row;

    IF NOT FOUND THEN
        -- lost a race with a concurrent identical request: return the winner's order
        SELECT * INTO v_row FROM pay_orders
         WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code AND idempotency_key = p_idempotency_key;
        IF v_row.request_hash <> v_hash THEN
            RAISE EXCEPTION 'idempotency key "%" was already used for a different order request.', p_idempotency_key
                USING ERRCODE = 'PY036';
        END IF;
        o_is_new := FALSE;
    ELSE
        o_is_new := TRUE;
    END IF;
    o_order_ref := v_row.order_ref; o_status := v_row.status; o_gateway_order_id := v_row.gateway_order_id;
    o_amount_minor := v_row.amount_minor; o_currency := v_row.currency; o_gateway_code := v_row.gateway_code;
    o_mode := v_row.mode; o_purpose := v_row.purpose;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
