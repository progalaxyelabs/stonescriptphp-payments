-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _wlt_import_opening_balances (INTERNAL; a migration or an operator session)
--
-- Imports a legacy wallet's opening balances as ONE 'migration' grant per wallet, posted to the ledger from src:opening.
-- p_rows: JSON array of {tenant_id, platform_code, credits}; credits is the legacy unit as a decimal STRING ("12.5"); p_scale converts the
-- legacy unit to milli-credits (1000 for whole credits, 1 when the legacy table already counts milli-credits). A value that does not
-- come to a whole number of milli-credits, a non-positive value or a non-UUID tenant is REJECTED (counted, never rounded).
-- Idempotent: key 'open:<tenant>:<platform>'. A second import of the SAME numbers changes nothing (o_already). If the legacy balance has MOVED since the
-- first import (same wallet, different credits) nothing is changed either - rewriting a posted opening balance would break the books - but it is
-- COUNTED in o_changed and the reconciliation gate _wlt_verify_opening reports it: freeze the legacy wallets, then import. Rows are processed in
-- (tenant, platform) order, so concurrent imports take wallet locks in the same order and cannot deadlock.
-- Reconcile by comparing o_total_milli with the legacy table's sum times p_scale, and run _wlt_verify_opening before any v2 traffic.
CREATE OR REPLACE FUNCTION _wlt_import_opening_balances(p_rows JSONB, p_scale BIGINT, p_actor TEXT, p_at TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (o_imported INTEGER, o_already INTEGER, o_rejected INTEGER, o_total_milli BIGINT, o_changed INTEGER) AS $$
DECLARE
    v_r      JSONB;
    v_milli  NUMERIC;
    v_wallet BIGINT;
    v_key    TEXT;
    v_hash   TEXT;
    v_g      wlt_grants;
BEGIN
    IF p_actor IS NULL OR btrim(p_actor) = '' OR p_scale IS NULL OR p_scale < 1 THEN
        RAISE EXCEPTION '_wlt_import_opening_balances: actor and a positive scale are required.' USING ERRCODE = 'PY070';
    END IF;
    o_imported := 0; o_already := 0; o_rejected := 0; o_total_milli := 0; o_changed := 0;
    FOR v_r IN SELECT e FROM jsonb_array_elements(p_rows) e ORDER BY e->>'tenant_id', e->>'platform_code'
    LOOP
        IF (v_r->>'tenant_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' OR coalesce(v_r->>'platform_code', '') = ''
           OR (v_r->>'credits') !~ '^[0-9]+(\.[0-9]+)?$' THEN
            o_rejected := o_rejected + 1; CONTINUE;
        END IF;
        v_milli := (v_r->>'credits')::numeric * p_scale;
        IF v_milli <= 0 OR v_milli <> trunc(v_milli) THEN
            o_rejected := o_rejected + 1; CONTINUE;
        END IF;
        v_key := 'open:' || (v_r->>'tenant_id') || ':' || (v_r->>'platform_code');
        v_hash := encode(sha256(convert_to(concat_ws('|', 'open', v_milli::text), 'UTF8')), 'hex');
        v_wallet := _wlt_wallet_lock((v_r->>'tenant_id')::uuid, v_r->>'platform_code');
        SELECT * INTO v_g FROM wlt_grants WHERE wallet_id = v_wallet AND grant_key = v_key;
        IF FOUND THEN
            IF v_g.request_hash = v_hash THEN o_already := o_already + 1; ELSE o_changed := o_changed + 1; END IF;
            CONTINUE;
        END IF;
        INSERT INTO wlt_grants (wallet_id, source, granted_milli, remaining_milli, grant_key, granted_at, created_by, request_hash)
        VALUES (v_wallet, 'migration', v_milli::bigint, v_milli::bigint, v_key, p_at, p_actor, v_hash);
        PERFORM _ledger_post('opening', v_key, p_at, jsonb_build_array(
            jsonb_build_object('account', 'wallet:' || v_wallet, 'amount_milli', v_milli::bigint),
            jsonb_build_object('account', 'src:opening', 'amount_milli', -v_milli::bigint)));
        o_imported := o_imported + 1; o_total_milli := o_total_milli + v_milli::bigint;
    END LOOP;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- _wlt_verify_opening: the reconciliation GATE. For every legacy row it compares the legacy balance (credits x scale, in milli-credits) with the wallet's
-- spendable balance at p_as_of and returns ONLY the differences (zero rows = the wallets reconcile to the last milli-credit). Run it right after the
-- import and before any v2 traffic or any v2 drain: once the wallet is used, its balance legitimately moves. A row that is not a UUID, has no wallet, or
-- whose credits do not convert to whole milli-credits is a difference.
CREATE OR REPLACE FUNCTION _wlt_verify_opening(p_rows JSONB, p_scale BIGINT, p_as_of TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (o_tenant_id TEXT, o_platform_code TEXT, o_expected_milli NUMERIC, o_actual_milli BIGINT, o_note TEXT) AS $$
DECLARE
    v_r   JSONB;
    v_exp NUMERIC;
    v_act BIGINT;
BEGIN
    FOR v_r IN SELECT e FROM jsonb_array_elements(p_rows) e ORDER BY e->>'tenant_id', e->>'platform_code'
    LOOP
        o_tenant_id := v_r->>'tenant_id'; o_platform_code := v_r->>'platform_code'; o_expected_milli := NULL; o_actual_milli := NULL;
        IF (v_r->>'tenant_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' OR (v_r->>'credits') !~ '^[0-9]+(\.[0-9]+)?$' THEN
            o_note := 'row is not importable'; RETURN NEXT; CONTINUE;
        END IF;
        v_exp := (v_r->>'credits')::numeric * p_scale;
        o_expected_milli := v_exp;
        IF v_exp <> trunc(v_exp) THEN
            o_note := 'credits do not convert to whole milli-credits'; RETURN NEXT; CONTINUE;
        END IF;
        SELECT o_milli INTO v_act FROM wallet_balance((v_r->>'tenant_id')::uuid, v_r->>'platform_code', p_as_of);
        o_actual_milli := v_act;
        IF v_exp = 0 AND coalesce(v_act, 0) = 0 THEN CONTINUE; END IF;
        IF v_act IS DISTINCT FROM v_exp::bigint THEN
            o_note := CASE WHEN NOT EXISTS (SELECT 1 FROM wlt_wallets w WHERE w.tenant_id = (v_r->>'tenant_id')::uuid AND w.platform_code = v_r->>'platform_code')
                           THEN 'no wallet' ELSE 'balance differs' END;
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql STABLE;

-- _wlt_mark_platform_migrated: the per-platform switch that retires the v1 mint path. Once set, the v1 functions topup_wallet, grant_free_credits and
-- record_wallet_drain RAISE (PY074) for that platform, so nothing can credit or debit the old wallet behind the new one's back. Audited by pay_config's note.
CREATE OR REPLACE FUNCTION _wlt_mark_platform_migrated(p_platform VARCHAR(50), p_actor TEXT) RETURNS TEXT AS $$
BEGIN
    IF p_platform IS NULL OR btrim(p_platform) = '' OR p_actor IS NULL OR btrim(p_actor) = '' THEN
        RAISE EXCEPTION '_wlt_mark_platform_migrated: platform and actor are required.' USING ERRCODE = 'PY070';
    END IF;
    INSERT INTO pay_config (config_key, config_value, note) VALUES ('wallet_v2:' || p_platform, '1', 'v1 wallet retired by ' || p_actor || ' at ' || now()::text)
    ON CONFLICT (config_key) DO UPDATE SET config_value = '1', note = EXCLUDED.note;
    RETURN 'wallet v2 is now the only wallet for platform ' || p_platform;
END;
$$ LANGUAGE plpgsql;
