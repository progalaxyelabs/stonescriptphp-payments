-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_gst_resolve_state — split from Gst/025_gst_state_codes.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: CBIC GST state/UT codes — PORT of `Support/GstStateCodes.php`
--
-- The state-code table is DATA, not code (the "every VALUE is DATA" principle).
-- Two tables: the canonical code->name set, and the accepted name aliases
-- (lowercase, incl. common spelling/punctuation variants) -> code. Functions carry
-- only the lookup FORMULA. `resolve()` returns NULL (never a guess) for an
-- unassigned 2-digit code ('00','28','92','99') or an unrecognised name.

-- Resolve a state/UT NAME (or an already-2-digit code) to its canonical code,
-- or NULL. Mirrors GstStateCodes::resolve — a 2-digit input is validated against
-- the REAL assigned set (not merely its shape), so '00'/'28'/'92'/'99' -> NULL.

CREATE OR REPLACE FUNCTION inv_gst_resolve_state(p_state_name_or_code TEXT)
RETURNS TEXT AS $$
DECLARE
    v_trim TEXT := btrim(COALESCE(p_state_name_or_code, ''));
    v_code TEXT;
BEGIN
    IF v_trim = '' THEN
        RETURN NULL;
    END IF;
    IF v_trim ~ '^\d{2}$' THEN
        SELECT code INTO v_code FROM inv_gst_state_codes WHERE code = v_trim;
        RETURN v_code;  -- NULL if the 2-digit code is not a real assigned one
    END IF;
    SELECT code INTO v_code FROM inv_gst_state_name_aliases WHERE alias = lower(v_trim);
    RETURN v_code;
END;
$$ LANGUAGE plpgsql STABLE;
