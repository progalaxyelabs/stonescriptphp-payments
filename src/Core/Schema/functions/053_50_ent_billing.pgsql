-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _ent_period_at, _ent_billing_due, _ent_billing_run_one (INTERNAL; run by bin/pay-entitlement billing-run)
--
-- THE postpaid billing run, one entitlement per transaction:
--   _ent_period_at(anchor, n, interval)   the start of period n: anchor + n x interval computed in the billing zone (pay_config 'billing_timezone',
--                                         Asia/Kolkata) FROM THE ANCHOR, never chained from the previous boundary, and independent of the session
--                                         TimeZone. A 31 January anchor gives 28/29 Feb, then 31 Mar, 30 Apr ... and back to 31 Jan.
--   _ent_billing_due(as_of, limit)        ids of postpaid entitlements with a period to invoice and not backed off (read-only).
--   _ent_billing_run_one(id, as_of, actor) invoices every due period of ONE entitlement (at most ent_billing_catchup_max_periods), oldest first,
--                                         with the next gapless number of its series, issued and moved to 'due'. The runner calls it once per
--                                         entitlement, each in its own transaction, so the series counter lock is held for one invoice's work and
--                                         released, never across the whole run. A period is billed once ((entitlement, period) is unique, and the
--                                         row is taken SKIP LOCKED, so concurrent runners never double-bill or wait).
--   A failure rolls back that period (no invoice, no number), is recorded on the entitlement (billing_failures, billing_last_error) and backs
--   it off exponentially (ent_billing_backoff_*), so one broken entitlement can never starve the others; the success clears it. The runner raises
--   an alert with a stable token for every failure row.
-- The invoice is dated p_as_of; the CLI passes now() (the live document-date window applies).
CREATE OR REPLACE FUNCTION _ent_period_at(p_anchor TIMESTAMPTZ, p_n INTEGER, p_dur INTERVAL) RETURNS TIMESTAMPTZ AS $$
    SELECT ((p_anchor AT TIME ZONE _pay_billing_tz()) + (p_dur * p_n)) AT TIME ZONE _pay_billing_tz();
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION _ent_billing_due(p_as_of TIMESTAMPTZ DEFAULT now(), p_limit INTEGER DEFAULT 100)
RETURNS TABLE (o_entitlement_id BIGINT) AS $$
BEGIN
    -- plpgsql on purpose: it names columns (billing_retry_at) that a database upgraded from an earlier build only gets AFTER the functions are deployed
    -- (the gateway deploys functions first), and a LANGUAGE sql body is validated at creation
    RETURN QUERY SELECT e.id FROM ent_entitlements e
     WHERE e.billing_mode = 'postpaid' AND e.status NOT IN ('ended', 'suspended') AND e.next_billing_at <= _pay_clamp_future(p_as_of)
       AND (e.billing_retry_at IS NULL OR e.billing_retry_at <= now())
     ORDER BY e.next_billing_at, e.id LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- _ent_billing_fail: records a billing failure on the entitlement and schedules its retry (exponential, capped). Called from the handlers below.
CREATE OR REPLACE FUNCTION _ent_billing_fail(p_entitlement_id BIGINT, p_state TEXT, p_msg TEXT) RETURNS VOID AS $$
BEGIN
    UPDATE ent_entitlements SET billing_failures = billing_failures + 1,
           billing_retry_at = now() + make_interval(secs => least(_pay_config_int('ent_billing_backoff_cap_seconds'),
                               _pay_config_int('ent_billing_backoff_base_seconds') * (2 ^ least(billing_failures, 20))::bigint)::int),
           billing_last_error = left(p_state || ': ' || p_msg, 500)
     WHERE id = p_entitlement_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _ent_billing_run_one(p_entitlement_id BIGINT, p_as_of TIMESTAMPTZ DEFAULT now(), p_actor TEXT DEFAULT 'billing-run')
RETURNS TABLE (o_period_start TIMESTAMPTZ, o_period_end TIMESTAMPTZ, o_invoice_id BIGINT, o_error TEXT) AS $$
DECLARE
    v_ent    ent_entitlements;
    v_spp    RECORD;
    v_prof   JSONB;
    v_spec   JSONB;
    v_dur    INTERVAL;
    v_start  TIMESTAMPTZ;
    v_end    TIMESTAMPTZ;
    v_n      INTEGER;
    v_done   INTEGER := 0;
    v_inv    BIGINT;
    v_max    INTEGER := _pay_config_int('ent_billing_catchup_max_periods')::int;
    v_as_of  TIMESTAMPTZ := _pay_clamp_future(p_as_of);       -- a future date means nothing (and null means now)
BEGIN
    SELECT * INTO v_ent FROM ent_entitlements WHERE id = p_entitlement_id AND billing_mode = 'postpaid' AND status NOT IN ('ended', 'suspended') FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN
        RETURN;                                            -- gone, not postpaid, or another runner holds it
    END IF;
    -- EVERYTHING that can fail on a malformed row (a missing plan, an unreadable interval, a broken profile) is inside this block, so one poison
    -- entitlement records its failure and backs off, and can never stall the run.
    BEGIN
        SELECT spp.id, spp.amount, spp.is_amount_tax_exclusive, spp.duration, spp.duration_uom, pp.name INTO v_spp
          FROM subscription_pricing_plans spp JOIN pricing_plans pp ON pp.id = spp.pricing_plan_id WHERE spp.id = v_ent.subscription_pricing_plan_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'entitlement % has no postpaid plan (subscription_pricing_plan_id %).', v_ent.id, v_ent.subscription_pricing_plan_id USING ERRCODE = 'PY060';
        END IF;
        v_dur := (v_spp.duration || ' ' || v_spp.duration_uom)::interval;
        v_prof := v_ent.billing_profile;
        -- periods are counted from the CURRENT billing anchor: runs of an earlier postpaid stint (before a postpaid -> prepaid -> postpaid re-switch) do not count
        SELECT count(*) INTO v_n FROM ent_billing_runs WHERE entitlement_id = v_ent.id AND period_start >= v_ent.started_at;

        WHILE v_done < v_max LOOP
            v_start := _ent_period_at(v_ent.started_at, v_n, v_dur);
            v_end   := _ent_period_at(v_ent.started_at, v_n + 1, v_dur);
            EXIT WHEN v_end > v_as_of;
            BEGIN
                v_spec := jsonb_build_object(
                    'buyer', v_prof->'buyer', 'billing_country_code', v_prof->>'billing_country_code', 'billing_state', v_prof->>'billing_state',
                    'supply_type', coalesce(v_prof->>'supply_type', 'domestic'), 'document_type', v_prof->>'document_type',
                    'price_is_inclusive', NOT v_spp.is_amount_tax_exclusive, 'round_off', coalesce((v_prof->>'round_off')::boolean, false),
                    'lines', jsonb_build_array(jsonb_build_object(
                        'description', v_spp.name || ' (' || to_char(v_start AT TIME ZONE _pay_billing_tz(), 'DD Mon YYYY') || ' to '
                                       || to_char((v_end - interval '1 second') AT TIME ZONE _pay_billing_tz(), 'DD Mon YYYY') || ')',
                        'hsn_sac', v_prof->>'hsn_sac', 'quantity', '1',
                        'unit_price', to_char(v_spp.amount / 100.0, 'FM999999999990.00'), 'gst_rate', (v_prof->>'gst_rate')::numeric)));
                v_inv := inv_issue_invoice(
                    NULL, v_ent.tenant_id, v_ent.platform_code, 'postpaid_cycle', 'ent:' || v_ent.id || ':' || to_char(v_ent.started_at AT TIME ZONE 'UTC', 'YYYYMMDD"T"HH24MISS') || ':' || v_n,
                    v_start, v_end, v_as_of + make_interval(days => coalesce((v_prof->>'due_days')::int, 0)),
                    v_prof->>'billing_country_code', v_prof->>'billing_state', NULL, _pay_order_spec_buyer(v_spec),
                    v_spec->>'supply_type', v_spec->>'document_type', (v_spec->>'price_is_inclusive')::boolean, (v_spec->>'round_off')::boolean,
                    'INR', NULL, NULL, v_as_of, _pay_order_spec_lines(v_spec), NULL, p_actor, now(), 'issued', v_prof->>'series_code', v_prof->>'mode');
                PERFORM inv_transition_invoice_status(v_inv, v_ent.tenant_id, v_ent.platform_code, 'due', p_actor, v_as_of);
                INSERT INTO ent_billing_runs (entitlement_id, period_start, period_end, invoice_id) VALUES (v_ent.id, v_start, v_end, v_inv);
            EXCEPTION WHEN OTHERS THEN
                -- THIS period's savepoint rolled back (no invoice, no number, no run row); periods already invoiced in this call stay.
                PERFORM _ent_billing_fail(v_ent.id, SQLSTATE, SQLERRM);
                o_period_start := v_start; o_period_end := v_end; o_invoice_id := NULL; o_error := 'ENT_BILLING_FAILED ' || SQLSTATE || ': ' || SQLERRM;
                RETURN NEXT;
                RETURN;
            END;
            v_n := v_n + 1; v_done := v_done + 1;
            UPDATE ent_entitlements SET next_billing_at = _ent_period_at(v_ent.started_at, v_n + 1, v_dur), updated_at = greatest(v_as_of, updated_at), updated_by = p_actor,
                   billing_failures = 0, billing_retry_at = NULL, billing_last_error = NULL
             WHERE id = v_ent.id;
            o_period_start := v_start; o_period_end := v_end; o_invoice_id := v_inv; o_error := NULL;
            RETURN NEXT;
        END LOOP;
    EXCEPTION WHEN OTHERS THEN
        -- a failure in the SETUP (a missing plan, an unreadable interval, a broken profile): nothing was invoiced in this call
        PERFORM _ent_billing_fail(v_ent.id, SQLSTATE, SQLERRM);
        o_period_start := v_start; o_period_end := v_end; o_invoice_id := NULL; o_error := 'ENT_BILLING_FAILED ' || SQLSTATE || ': ' || SQLERRM;
        RETURN NEXT;
    END;
END;
$$ LANGUAGE plpgsql;
