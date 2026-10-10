-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: wlt_guard, ledger_balanced_check (trigger functions)
-- wlt_grants: never deleted; only remaining_milli (down) and forfeited_milli (up) move, and never past granted. Every other wallet/ledger
-- table is append-only. PY073. ledger_balanced_check: a deferred constraint - every posting must balance by commit (PY072).
CREATE OR REPLACE FUNCTION wlt_guard() RETURNS TRIGGER AS $$
BEGIN
    IF TG_TABLE_NAME = 'wlt_wallets' AND TG_OP = 'UPDATE' THEN
        IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id OR NEW.platform_code IS DISTINCT FROM OLD.platform_code OR NEW.code IS DISTINCT FROM OLD.code THEN
            RAISE EXCEPTION 'a wallet''s tenant, platform and code never change.' USING ERRCODE = 'PY073';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_TABLE_NAME = 'wlt_meters' AND TG_OP = 'UPDATE' THEN
        IF NEW.wallet_id IS DISTINCT FROM OLD.wallet_id OR NEW.meter_key IS DISTINCT FROM OLD.meter_key OR NEW.rate_num IS DISTINCT FROM OLD.rate_num
           OR NEW.rate_den IS DISTINCT FROM OLD.rate_den OR NEW.debited_milli < OLD.debited_milli OR NEW.cumulative < OLD.cumulative
           OR (OLD.closed_at IS NOT NULL AND NEW.closed_at IS DISTINCT FROM OLD.closed_at) THEN
            RAISE EXCEPTION 'meter %: identity and rate never change, and totals only grow.', OLD.id USING ERRCODE = 'PY073';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_TABLE_NAME = 'wlt_grants' AND TG_OP = 'UPDATE' THEN
        IF NEW.wallet_id IS DISTINCT FROM OLD.wallet_id OR NEW.source IS DISTINCT FROM OLD.source OR NEW.granted_milli IS DISTINCT FROM OLD.granted_milli
           OR NEW.amount_paid IS DISTINCT FROM OLD.amount_paid OR NEW.grant_key IS DISTINCT FROM OLD.grant_key OR NEW.granted_at IS DISTINCT FROM OLD.granted_at
           OR NEW.expires_at IS DISTINCT FROM OLD.expires_at OR NEW.gateway_txn_ref IS DISTINCT FROM OLD.gateway_txn_ref OR NEW.request_hash IS DISTINCT FROM OLD.request_hash
           OR NEW.gateway_code IS DISTINCT FROM OLD.gateway_code OR NEW.unit_price_pinned IS DISTINCT FROM OLD.unit_price_pinned OR NEW.created_by IS DISTINCT FROM OLD.created_by
           OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
            RAISE EXCEPTION 'wallet grant %: what was granted never changes; only the remaining credit moves.', OLD.id USING ERRCODE = 'PY073';
        END IF;
        IF NEW.remaining_milli > OLD.remaining_milli OR NEW.forfeited_milli < OLD.forfeited_milli THEN
            RAISE EXCEPTION 'wallet grant %: remaining credit only decreases.', OLD.id USING ERRCODE = 'PY073';
        END IF;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION '% is append-only / never deleted (%).', TG_TABLE_NAME, TG_OP USING ERRCODE = 'PY073';
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ledger_balanced_check() RETURNS TRIGGER AS $$
DECLARE
    v_sum NUMERIC;
BEGIN
    SELECT coalesce(sum(amount_milli), 0) INTO v_sum FROM ledger_entries WHERE txn_id = NEW.txn_id;
    IF v_sum <> 0 THEN
        RAISE EXCEPTION 'ledger posting % does not balance (sum %).', NEW.txn_id, v_sum USING ERRCODE = 'PY072';
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- wlt_config_guard: pay_config 'wallet_milli_per_credit' (the display unit of every stored milli-credit) can never change once ANY grant exists:
-- changing it would silently re-denominate every balance.
CREATE OR REPLACE FUNCTION wlt_config_guard() RETURNS TRIGGER AS $$
BEGIN
    IF OLD.config_key = 'wallet_milli_per_credit' AND (TG_OP = 'DELETE' OR NEW.config_value IS DISTINCT FROM OLD.config_value OR NEW.config_key IS DISTINCT FROM OLD.config_key)
       AND EXISTS (SELECT 1 FROM wlt_grants) THEN
        RAISE EXCEPTION 'wallet_milli_per_credit cannot change once any wallet credit exists: it would re-denominate every balance.' USING ERRCODE = 'PY073';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
