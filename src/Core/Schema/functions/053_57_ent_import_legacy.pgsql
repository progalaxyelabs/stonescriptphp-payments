-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _ent_import_legacy (INTERNAL; a migration or an operator session)
--
-- Copies the rows of a legacy `subscriptions`-shaped table (tenant_id text, platform_code, plan_code, status, started_at, expires_at,
-- cancelled_at) into ent_entitlements as source 'migration' ('trial' for a trial). Idempotent, audited (one ent_activations row per import,
-- key 'legacy:<platform>:<tenant>'), and it changes no one's access: the mapping preserves the legacy decision (see _ent_verify_legacy).
--   trial -> trial; active -> active; cancelled -> active until expires_at (cancel-at-period-end), ended once past;
--   suspended | refunded | chargeback -> suspended; expires_at 'infinity' -> no end;
--   expires_at NULL (the legacy rule "expires_at > now" is then never true) -> already expired AT the cancellation time (or the start), and a
--   cancelled row with no end is 'ended', never active forever.
-- A row whose tenant_id is not a UUID or whose status is unknown is counted as invalid and skipped, never guessed.
--
-- p_sync = true is the FINAL DELTA IMPORT of a cutover window: a tenant that already has an entitlement is UPDATED to the legacy row when that
-- entitlement is still purely the product of an earlier import (every activation is 'migration' and nothing since came from a payment, a comp or an
-- operator), so renewals written to the legacy table after the first import are carried over; one that has moved on in ent_* is left alone and
-- counted in o_skipped_newer. The comparison is between the CURRENT legacy row and the CURRENT entitlement (never a remembered hash), so a legacy row
-- changed and then reverted is synced back correctly. Run it again after the legacy writers have stopped (README, "Cutover runbook").
CREATE OR REPLACE FUNCTION _ent_import_legacy(p_legacy REGCLASS, p_actor TEXT, p_at TIMESTAMPTZ DEFAULT now(), p_sync BOOLEAN DEFAULT FALSE)
RETURNS TABLE (o_imported INTEGER, o_already INTEGER, o_invalid INTEGER, o_synced INTEGER, o_skipped_newer INTEGER) AS $$
DECLARE
    v_row    RECORD;
    v_ent    ent_entitlements;
    v_old    ent_entitlements;
    v_tenant UUID;
    v_status TEXT;
    v_end    TIMESTAMPTZ;
    v_hash   TEXT;
    v_at     TIMESTAMPTZ := coalesce(p_at, now());     -- an explicit NULL from a caller means "now", never "no time"
    v_src    TEXT;
BEGIN
    IF p_actor IS NULL OR btrim(p_actor) = '' THEN
        RAISE EXCEPTION '_ent_import_legacy: actor is required.' USING ERRCODE = 'PY060';
    END IF;
    o_imported := 0; o_already := 0; o_invalid := 0; o_synced := 0; o_skipped_newer := 0;
    FOR v_row IN EXECUTE format('SELECT tenant_id::text AS tenant_id, platform_code::text AS platform_code, plan_code::text AS plan_code, status::text AS status, '
                                'started_at, expires_at, cancelled_at FROM %s ORDER BY 2, 1', p_legacy)
    LOOP
        IF v_row.tenant_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
           OR v_row.status NOT IN ('trial', 'active', 'cancelled', 'suspended', 'refunded', 'chargeback') THEN
            o_invalid := o_invalid + 1; CONTINUE;
        END IF;
        v_tenant := v_row.tenant_id::uuid;
        v_end := CASE WHEN v_row.expires_at = 'infinity'::timestamptz THEN NULL
                      WHEN v_row.expires_at IS NULL THEN coalesce(v_row.cancelled_at, v_row.started_at)
                      ELSE v_row.expires_at END;
        v_status := CASE v_row.status
                      WHEN 'trial' THEN 'trial'
                      WHEN 'active' THEN 'active'
                      WHEN 'cancelled' THEN CASE WHEN v_end IS NULL OR v_end > v_at THEN 'active' ELSE 'ended' END
                      ELSE 'suspended' END;
        v_hash := encode(sha256(convert_to(concat_ws('|', v_row.tenant_id, v_row.platform_code, v_row.plan_code, v_row.status, v_row.started_at::text, v_row.expires_at::text, v_row.cancelled_at::text), 'UTF8')), 'hex');

        SELECT * INTO v_old FROM ent_entitlements WHERE tenant_id = v_tenant AND platform_code = v_row.platform_code AND product = 'default' FOR UPDATE;
        IF FOUND THEN
            IF NOT p_sync THEN
                o_already := o_already + 1; CONTINUE;
            END IF;
            v_src := CASE WHEN v_row.status = 'trial' THEN 'trial' ELSE 'migration' END;
            IF EXISTS (SELECT 1 FROM ent_activations WHERE entitlement_id = v_old.id AND kind <> 'migration') THEN
                o_skipped_newer := o_skipped_newer + 1;                       -- it has moved on in ent_*: not ours to overwrite
                CONTINUE;
            END IF;
            IF v_old.status = v_status AND v_old.plan_ref IS NOT DISTINCT FROM left(v_row.plan_code, 50) AND v_old.started_at = v_row.started_at
               AND v_old.current_period_end IS NOT DISTINCT FROM v_end AND v_old.source = v_src THEN
                o_already := o_already + 1; CONTINUE;                          -- the legacy row equals the entitlement already
            END IF;
            UPDATE ent_entitlements SET status = v_status, plan_ref = left(v_row.plan_code, 50), started_at = v_row.started_at, current_period_end = v_end,
                   source = v_src, updated_at = v_at, updated_by = p_actor
             WHERE id = v_old.id RETURNING * INTO v_ent;
            INSERT INTO ent_activations (entitlement_id, tenant_id, platform_code, product, kind, plan_ref, idempotency_key, request_hash, actor, reason, period_from, period_to, created_at)
            VALUES (v_ent.id, v_tenant, v_row.platform_code, 'default', 'migration', v_ent.plan_ref,
                    'legacy-sync:' || v_row.platform_code || ':' || v_row.tenant_id || ':' || (SELECT count(*) FROM ent_activations WHERE entitlement_id = v_ent.id),
                    v_hash, p_actor, 'delta import from ' || p_legacy::text, v_row.started_at, v_end, v_at);
            o_synced := o_synced + 1;
            CONTINUE;
        END IF;

        INSERT INTO ent_entitlements (tenant_id, platform_code, product, status, plan_ref, started_at, current_period_end, billing_mode, source, created_at, updated_at, updated_by)
        VALUES (v_tenant, v_row.platform_code, 'default', v_status, left(v_row.plan_code, 50), v_row.started_at, v_end, 'prepaid',
                CASE WHEN v_row.status = 'trial' THEN 'trial' ELSE 'migration' END, v_at, v_at, p_actor)
        RETURNING * INTO v_ent;
        INSERT INTO ent_activations (entitlement_id, tenant_id, platform_code, product, kind, plan_ref, idempotency_key, request_hash, actor, reason, period_from, period_to, created_at)
        VALUES (v_ent.id, v_tenant, v_row.platform_code, 'default', 'migration', v_ent.plan_ref, 'legacy:' || v_row.platform_code || ':' || v_row.tenant_id,
                v_hash, p_actor, 'imported from ' || p_legacy::text, v_row.started_at, v_end, v_at);
        o_imported := o_imported + 1;
    END LOOP;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
