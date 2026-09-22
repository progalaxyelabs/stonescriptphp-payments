-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Metering :: functions :: get_postpaid_charges_due — split from 022_postpaid_billing.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: an example vertical's POSTPAID subscription, billed in arrears (Case 5)
-- =====================================================================
-- Two gaps closed here:
--  (a) No catalog existed at all — added: Monthly + a 10-for-12
--      Annual (pay for 10 months, get 12 = 16.67% off vs 12× monthly).
--  (b) Every seeded plan was PREPAID (is_post_paid=false); this example
--      exercises a POSTPAID collection model: a monthly invoice raised in
--      ARREARS at the end of each covered period, 30-day due, then read-only
--      until paid (a postpaid monthly-invoice collection model).
--      The schema already carries is_post_paid on subscription_pricing_plans;
--      it was just never exercised. get_postpaid_charges_due() below exercises
--      it — the invoice for a period is due AT that period's expiry, not at its
--      start.
--
-- Prices are example config rows (editable) — the SHAPE (monthly + 10-for-12
-- annual, postpaid) is the example model. is_amount_tax_exclusive=true (GST
-- added by the invoice module). The 30-day-due / read-only-until-paid gating
-- is an APP-LAYER policy on top of "what is owed and when" — out of scope for
-- this pricing/entitlement layer, which only answers the amount + due date.

-- Postpaid invoices due in a window: one per covered period of a postpaid
-- subscription whose period ENDS (expires_at) inside [p_from, p_to]. Prepaid
-- plans never appear (nothing is billed in arrears for them). A period
-- cancelled before it completed is excluded here (mid-cycle postpaid proration
-- is a separate concern — the credit ledger in 020 banks such adjustments).

CREATE OR REPLACE FUNCTION get_postpaid_charges_due(p_tenant_id UUID, p_platform_code VARCHAR(50), p_from TIMESTAMPTZ, p_to TIMESTAMPTZ)
RETURNS TABLE (
    customer_pricing_plan_id     BIGINT,
    pricing_plan_id              BIGINT,
    pricing_plan_name            TEXT,
    subscription_pricing_plan_id BIGINT,
    amount                       BIGINT,
    is_amount_tax_exclusive      BOOLEAN,
    period_start                 TIMESTAMPTZ,
    invoice_due_at               TIMESTAMPTZ
) AS $$
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR p_platform_code = '' THEN
        RAISE EXCEPTION 'tenant_id and platform_code are required' USING ERRCODE = 'ER001';
    END IF;

    RETURN QUERY
    SELECT cpp.id, pp.id, pp.name, spp.id, spp.amount, spp.is_amount_tax_exclusive,
           cpp.started_at,
           cpp.started_at + (spp.duration || ' ' || spp.duration_uom)::interval AS invoice_due_at
    FROM customer_pricing_plans cpp
    JOIN pricing_plans pp ON pp.id = cpp.pricing_plan_id
    JOIN subscription_pricing_plans spp ON spp.id = cpp.subscription_pricing_plan_id
    WHERE cpp.tenant_id = p_tenant_id AND cpp.platform_code = p_platform_code
      AND spp.is_post_paid = true
      AND cpp.cancelled_at IS NULL
      AND (cpp.started_at + (spp.duration || ' ' || spp.duration_uom)::interval) BETWEEN p_from AND p_to
    ORDER BY invoice_due_at;
END;
$$ LANGUAGE plpgsql;
