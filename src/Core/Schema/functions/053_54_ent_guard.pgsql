-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: ent_guard + triggers
-- ent_entitlements: never deleted, identity (tenant, platform, product) never changes. ent_activations and ent_billing_runs: append-only.
-- No table can be truncated. SQLSTATE PY063.
CREATE OR REPLACE FUNCTION ent_guard() RETURNS TRIGGER AS $$
BEGIN
    IF TG_TABLE_NAME = 'ent_entitlements' AND TG_OP = 'UPDATE' THEN
        IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id OR NEW.platform_code IS DISTINCT FROM OLD.platform_code OR NEW.product IS DISTINCT FROM OLD.product THEN
            RAISE EXCEPTION 'an entitlement''s tenant, platform and product never change.' USING ERRCODE = 'PY063';
        END IF;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION '% is append-only / never deleted (%).', TG_TABLE_NAME, TG_OP USING ERRCODE = 'PY063';
END;
$$ LANGUAGE plpgsql;
