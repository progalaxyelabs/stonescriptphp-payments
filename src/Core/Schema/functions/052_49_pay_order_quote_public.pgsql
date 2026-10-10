-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: pay_order_quote (PUBLIC, read-only)
--
-- The price a checkout or pricing page shows BEFORE an order exists: the line and tax breakdown and the total for an invoice spec
-- in a numbering series. Tenant-scoped: the series must belong to the platform and be visible to the tenant (a platform-level
-- issuer, or the tenant's own); a series of another platform or another tenant is refused (PY011). It writes nothing and
-- allocates no number. o_gross_minor is EXACTLY the amount pay_order_create will enforce for the same series, spec and currency
-- (both read _pay_order_compute), so a page that shows this number and creates the order with it can never be refused for a
-- mismatch. o_orderable is false when pay_order_create would refuse the order for a reason of the series itself (an inactive or
-- non-invoice series, or a live series whose issuer is still a placeholder).
CREATE OR REPLACE FUNCTION pay_order_quote(p_tenant_id UUID, p_platform_code VARCHAR(50), p_series_code TEXT, p_spec TEXT, p_currency TEXT)
RETURNS TABLE (
    o_series_code TEXT, o_mode TEXT, o_currency TEXT, o_document_type TEXT, o_tax_treatment TEXT, o_place_of_supply_code TEXT,
    o_taxable_minor BIGINT, o_cgst_minor BIGINT, o_sgst_minor BIGINT, o_igst_minor BIGINT, o_round_off_minor BIGINT,
    o_gross_minor BIGINT, o_lines JSONB, o_orderable BOOLEAN
) AS $$
DECLARE
    v_series inv_series;
    v_issuer inv_issuers;
    v_ci     inv_computed_invoice;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR btrim(p_platform_code) = '' OR p_series_code IS NULL OR p_spec IS NULL
       OR p_currency IS NULL THEN
        RAISE EXCEPTION 'pay_order_quote: tenant, platform, series, spec and currency are required.' USING ERRCODE = 'PY030';
    END IF;
    SELECT * INTO v_series FROM inv_series WHERE series_code = p_series_code;
    IF FOUND THEN
        SELECT * INTO v_issuer FROM inv_issuers WHERE id = v_series.issuer_id;
    END IF;
    IF NOT FOUND OR v_issuer.platform_code IS DISTINCT FROM p_platform_code
       OR (v_issuer.tenant_id IS NOT NULL AND v_issuer.tenant_id IS DISTINCT FROM p_tenant_id) THEN
        RAISE EXCEPTION 'series "%" is not available to this tenant and platform.', p_series_code USING ERRCODE = 'PY011';
    END IF;

    v_ci := _pay_order_compute(p_series_code, p_spec::jsonb, p_currency, now());
    o_series_code := v_series.series_code; o_mode := v_series.mode; o_currency := v_ci.currency;
    o_document_type := v_ci.document_type; o_tax_treatment := v_ci.tax_treatment; o_place_of_supply_code := v_ci.place_of_supply_code;
    o_taxable_minor := v_ci.taxable_value_minor; o_cgst_minor := v_ci.cgst_minor; o_sgst_minor := v_ci.sgst_minor;
    o_igst_minor := v_ci.igst_minor; o_round_off_minor := v_ci.round_off_minor; o_gross_minor := v_ci.gross_total_minor;
    o_lines := coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                   'description', l.description, 'hsn_sac', l.hsn_sac, 'quantity', l.quantity_str, 'unit_price_minor', l.unit_price_minor,
                   'gst_rate', l.gst_rate, 'taxable_minor', l.taxable_value_minor, 'cgst_minor', l.cgst_minor,
                   'sgst_minor', l.sgst_minor, 'igst_minor', l.igst_minor, 'line_total_minor', l.line_total_minor) ORDER BY o)
          FROM unnest(v_ci.lines) WITH ORDINALITY AS l(description, hsn_sac, quantity_milli, quantity_str, unit_price_minor, gst_rate,
                   taxable_value_minor, cgst_minor, sgst_minor, igst_minor, line_total_minor, taxable_value_str, cgst_str, sgst_str,
                   igst_str, line_total_str, o)), '[]'::jsonb);
    o_orderable := v_series.is_active AND v_series.kind = 'invoice' AND NOT (v_series.mode = 'live' AND v_issuer.is_placeholder);
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql STABLE;
