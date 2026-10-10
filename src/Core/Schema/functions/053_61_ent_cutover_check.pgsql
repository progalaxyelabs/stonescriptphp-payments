-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _ent_cutover_check (INTERNAL; the hard gate before the compatibility view replaces a legacy table)
--
-- RAISES (PY067) unless ALL of these hold for the platform's rows in the legacy table:
--   1. _ent_verify_legacy returns ZERO rows (the same active / read-only decision for every tenant at p_as_of);
--   2. no legacy row is invalid (a tenant id that is not a UUID, an unknown status);
--   3. the platform's missing-subscription behaviour in the library (_ent_missing_mode) equals the legacy platform's own setting (p_legacy_missing_mode).
-- Returns 'ok' with the number of rows checked. Run it as the LAST step before the rename, in the same window as the final delta import
-- (README, "Cutover runbook"): a check that passed yesterday proves nothing about a legacy table still being written today.
CREATE OR REPLACE FUNCTION _ent_cutover_check(p_legacy REGCLASS, p_platform VARCHAR(50), p_legacy_missing_mode TEXT, p_as_of TIMESTAMPTZ DEFAULT now())
RETURNS TEXT AS $$
DECLARE
    v_diffs   INTEGER;
    v_invalid INTEGER;
    v_rows    INTEGER;
BEGIN
    IF p_platform IS NULL OR btrim(p_platform) = '' OR p_legacy_missing_mode NOT IN ('read_only', 'allow') THEN
        RAISE EXCEPTION '_ent_cutover_check: platform and the legacy missing-subscription mode (read_only|allow) are required.' USING ERRCODE = 'PY060';
    END IF;
    EXECUTE format('SELECT count(*) FROM %s WHERE platform_code::text = $1', p_legacy) INTO v_rows USING p_platform;
    EXECUTE format($q$SELECT count(*) FROM %s WHERE platform_code::text = $1 AND (tenant_id::text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                       OR status::text NOT IN ('trial', 'active', 'cancelled', 'suspended', 'refunded', 'chargeback'))$q$, p_legacy) INTO v_invalid USING p_platform;
    SELECT count(*) INTO v_diffs FROM _ent_verify_legacy(p_legacy, p_as_of) WHERE o_platform_code = p_platform;
    IF v_invalid > 0 THEN
        RAISE EXCEPTION 'cutover blocked: % legacy row(s) of platform "%" are invalid (non-UUID tenant or unknown status).', v_invalid, p_platform USING ERRCODE = 'PY067';
    END IF;
    IF v_diffs > 0 THEN
        RAISE EXCEPTION 'cutover blocked: % legacy row(s) of platform "%" would change access (_ent_verify_legacy is not empty).', v_diffs, p_platform USING ERRCODE = 'PY067';
    END IF;
    IF _ent_missing_mode(p_platform) <> p_legacy_missing_mode THEN
        RAISE EXCEPTION 'cutover blocked: the library treats a tenant with no entitlement as "%" for platform "%" but the legacy platform treats it as "%" (_ent_set_missing_mode).',
            _ent_missing_mode(p_platform), p_platform, p_legacy_missing_mode USING ERRCODE = 'PY067';
    END IF;
    RETURN 'ok: ' || v_rows || ' legacy rows of "' || p_platform || '" verified';
END;
$$ LANGUAGE plpgsql STABLE;
