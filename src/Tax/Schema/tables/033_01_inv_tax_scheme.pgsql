-- package: progalaxyelabs/stonescriptphp-payments (merged from stonescriptphp-payments + stonescriptphp-invoice) v0.1.0
-- stonescriptphp-payments :: Tax :: tables :: inv_tax_scheme — the country-agnostic
-- "which tax regime applies" resolution DATA, added at the 2026-09-22 merge.
--
-- WHY THIS EXISTS: the ecosystem's standing law (matching inv_resolve_gateway,
-- 035, which resolves a payment gateway by JOINing inv_gateway_routing_rules
-- on billing_country_code — never by executing a caller-supplied function
-- name) is that per-country routing/selection is DATA + a JOIN + a CASE on a
-- data COLUMN, never a dynamically-dispatched function name. This table is
-- that same pattern applied to TAX: which regime (scheme_type) governs an
-- invoice is resolved by joining THIS table on billing_country_code, not by
-- selecting/EXECUTE-ing a tax-engine function by constructed name.
--
-- TODAY: exactly one scheme is seeded ('IN' -> 'in_gst'), and
-- inv_compute_invoice (030, Tax/India) IS that scheme's implementation —
-- it is not renamed or restructured by this table's addition (it stays the
-- proven, differential-golden-tested India GST engine, called directly,
-- statically, by name, from inv_issue_invoice, exactly as before this
-- table existed). This table is deliberately ADDITIVE and inert: it changes
-- no existing behavior and is not yet wired into inv_issue_invoice's call
-- path. It exists so that the NEXT country added is a data INSERT (+ at
-- most one new, hardcoded CASE branch in a future country-agnostic
-- dispatcher) — never a new "pass a function name" parameter anywhere.
-- See inv_resolve_tax_scheme() (033) for the resolution function, and the
-- Tax/README note on the multi-country follow-on this scaffolds.

CREATE TABLE IF NOT EXISTS inv_tax_scheme (
    billing_country_code TEXT PRIMARY KEY,   -- ISO 3166-1 alpha-2, e.g. 'IN'
    scheme_type           TEXT NOT NULL,     -- 'in_gst' today; 'vat' | 'sales_tax' | 'none' are future CASE branches, not dynamic dispatch
    display_name           TEXT NOT NULL,
    is_active               BOOLEAN NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              TEXT NOT NULL
);
