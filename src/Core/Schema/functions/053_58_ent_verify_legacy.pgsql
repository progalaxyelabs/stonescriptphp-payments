-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _ent_verify_legacy (INTERNAL)
--
-- Proves the migration changed no one's access: for every row of the legacy table, "was this tenant active at p_as_of" (legacy rule:
-- expires_at in the future and status not suspended / refunded / chargeback) must equal "is this tenant not read-only" in ent_get.
-- Returns ONLY the differences (zero rows = equivalent). A row missing from ent_entitlements, or with a non-UUID tenant, is a difference.
CREATE OR REPLACE FUNCTION _ent_verify_legacy(p_legacy REGCLASS, p_as_of TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (o_tenant_id TEXT, o_platform_code TEXT, o_legacy_active BOOLEAN, o_entitlement_active BOOLEAN, o_note TEXT) AS $$
DECLARE
    v_row RECORD;
    v_ent RECORD;
    v_legacy_active BOOLEAN;
BEGIN
    FOR v_row IN EXECUTE format('SELECT tenant_id::text AS tenant_id, platform_code::text AS platform_code, status::text AS status, expires_at FROM %s ORDER BY 1, 2', p_legacy)
    LOOP
        v_legacy_active := coalesce(v_row.expires_at > p_as_of, FALSE) AND v_row.status NOT IN ('suspended', 'refunded', 'chargeback');
        o_tenant_id := v_row.tenant_id; o_platform_code := v_row.platform_code; o_legacy_active := v_legacy_active; o_entitlement_active := NULL;
        IF v_row.tenant_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
            o_note := 'tenant id is not a uuid'; RETURN NEXT; CONTINUE;
        END IF;
        SELECT * INTO v_ent FROM ent_get(v_row.tenant_id::uuid, v_row.platform_code, 'default', p_as_of);
        IF NOT v_ent.o_found THEN
            o_note := 'missing from ent_entitlements'; RETURN NEXT; CONTINUE;
        END IF;
        o_entitlement_active := NOT v_ent.o_read_only;
        IF o_entitlement_active IS DISTINCT FROM v_legacy_active THEN
            o_note := 'access decision differs'; RETURN NEXT;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql STABLE;
