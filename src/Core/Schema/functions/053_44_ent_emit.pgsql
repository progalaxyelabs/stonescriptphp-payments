-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _ent_emit (INTERNAL)
-- Appends an entitlement.changed event (inside the transaction that caused the change) for domain consumers.
CREATE OR REPLACE FUNCTION _ent_emit(p_ent ent_entitlements, p_kind TEXT, p_order_ref TEXT, p_extra JSONB DEFAULT '{}'::jsonb) RETURNS VOID AS $$
    INSERT INTO pay_events (event_type, tenant_id, platform_code, order_ref, payload)
    VALUES ('entitlement.changed', p_ent.tenant_id, p_ent.platform_code, p_order_ref,
            jsonb_build_object('kind', p_kind, 'product', p_ent.product, 'status', p_ent.status, 'plan_ref', p_ent.plan_ref,
                               'period_end', p_ent.current_period_end, 'source', p_ent.source) || coalesce(p_extra, '{}'::jsonb));
$$ LANGUAGE sql;
