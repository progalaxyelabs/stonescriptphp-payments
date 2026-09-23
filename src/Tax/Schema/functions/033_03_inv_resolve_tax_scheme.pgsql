-- package: progalaxyelabs/stonescriptphp-payments (merged from stonescriptphp-payments + stonescriptphp-invoice) v0.1.0
-- stonescriptphp-payments :: Tax :: functions :: inv_resolve_tax_scheme
--
-- Resolves which tax regime governs a billing country by a plain JOIN on
-- inv_tax_scheme (033) — mirrors inv_resolve_gateway's (035) own JOIN-based
-- resolution exactly, on purpose: country-keyed selection is ALWAYS data +
-- JOIN + a CASE on the returned scheme_type column, never a dynamically
-- constructed/EXECUTEd function name. No gateway-registered function in this
-- ecosystem may take a callable/function-name as a parameter.
--
-- Fails loud (never silently defaults to India GST) on an unmapped or
-- inactive country — ER065, the same "no fallback guessing" discipline
-- ER052 (inv_resolve_gateway) already established for gateway routing.
--
-- WIRED into inv_issue_invoice's call path (035, 2026-09-22): inv_issue_invoice
-- calls this function first, then CASE-dispatches on scheme_type to the
-- matching engine — a static, hardcoded call per branch, never a name lookup.
-- inv_compute_invoice (030) remains the single, proven, differential-golden-
-- tested 'in_gst' engine; it is unchanged and is still the only branch that
-- exists. The behavioural difference this wiring makes: a billing country
-- with no active inv_tax_scheme row now fails loud here (ER065) instead of
-- inv_issue_invoice previously calling inv_compute_invoice unconditionally
-- for ANY 2-letter country code.

CREATE OR REPLACE FUNCTION inv_resolve_tax_scheme(p_billing_country_code TEXT)
RETURNS TEXT AS $$
DECLARE
    v_scheme_type TEXT;
BEGIN
    IF p_billing_country_code IS NULL OR p_billing_country_code !~ '^[A-Za-z]{2}$' THEN
        RAISE EXCEPTION 'billing_country_code "%" must be a 2-letter ISO country code.', p_billing_country_code
            USING ERRCODE = 'ER060';
    END IF;

    SELECT scheme_type INTO v_scheme_type
      FROM inv_tax_scheme
     WHERE billing_country_code = upper(p_billing_country_code)
       AND is_active;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no active tax scheme is mapped for billing country "%". Add a row to inv_tax_scheme (never guess/default a tax regime).',
            upper(p_billing_country_code) USING ERRCODE = 'ER065';
    END IF;

    RETURN v_scheme_type;
END;
$$ LANGUAGE plpgsql STABLE;
