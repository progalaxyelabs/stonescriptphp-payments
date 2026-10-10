-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _pay_order_quote
--
-- Dry-run of the invoice an order's spec produces for a series' issuer: the pure tax engine,
-- nothing written, no number allocated. Returns the gross total and currency. Used at order
-- creation to refuse an order whose quoted amount is not what the invoice will total, and by
-- the capture to re-check the same thing.
-- _pay_order_compute is the one place the spec is turned into an invoice computation; _pay_order_quote (the amount
-- pay_order_create enforces) and the public pay_order_quote (the price a checkout page shows) both read it, so the two can never differ.
CREATE OR REPLACE FUNCTION _pay_order_compute(p_series_code TEXT, p_spec JSONB, p_currency TEXT, p_at TIMESTAMPTZ)
RETURNS inv_computed_invoice AS $$
DECLARE
    v_series inv_series;
    v_issuer inv_issuers;
BEGIN
    SELECT * INTO v_series FROM inv_series WHERE series_code = p_series_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'series "%" does not exist.', p_series_code USING ERRCODE = 'PY010';
    END IF;
    SELECT * INTO v_issuer FROM inv_issuers WHERE id = v_series.issuer_id;
    RETURN inv_compute_invoice(
        ROW(v_issuer.legal_name, v_issuer.gstin, 'seller', v_issuer.registration_status, NULL, v_issuer.state_code)::inv_party_input,
        _pay_order_spec_buyer(p_spec),
        coalesce(p_spec->>'supply_type', 'domestic'),
        p_spec->>'document_type',
        coalesce((p_spec->>'price_is_inclusive')::boolean, false),
        coalesce((p_spec->>'round_off')::boolean, false),
        p_currency, p_spec->>'fx_rate', p_spec->>'amount_inr',
        NULL, p_at, _pay_order_spec_lines(p_spec));
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION _pay_order_quote(p_series_code TEXT, p_spec JSONB, p_currency TEXT, p_at TIMESTAMPTZ)
RETURNS TABLE (o_gross_minor BIGINT, o_taxable_minor BIGINT) AS $$
DECLARE
    v_ci inv_computed_invoice;
BEGIN
    v_ci := _pay_order_compute(p_series_code, p_spec, p_currency, p_at);
    o_gross_minor := v_ci.gross_total_minor;
    o_taxable_minor := v_ci.taxable_value_minor;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql STABLE;
