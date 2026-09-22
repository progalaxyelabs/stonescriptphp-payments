-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Pricing :: functions :: get_customer_credit_balance — split from 031_fix_credit_balance_purchase_time_guard.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: FIX for the latent bug in 003 get_customer_credit_balance
--
-- SEPARATE, MINIMAL correctness fix (kept out of 001-023 per the standing
-- "do not edit the passing files" rule — delivered as a CREATE OR REPLACE
-- override that runs after 003, so the running DB gets the fixed body while the
-- 003 file stays byte-identical. Step 2 may fold this body back into 003.)
--
-- THE BUG: 003's FIFO consumption loop drew from a batch as long as the batch
-- had not EXPIRED at the consumption time — but never checked that the batch had
-- actually been PURCHASED at/before that consumption time. So a consumption
-- could draw credits from a batch bought AFTER it happened. The 017 wallet
-- function already guards this with `granted_at <= usage_at`; this adds the
-- identical guard (`batch_started_at <= consumed_at`) to 003.
--
-- Only ONE line of logic changes vs 003 (the new v_started[] array + the extra
-- AND term in the draw condition); everything else is a faithful copy of 003.

CREATE OR REPLACE FUNCTION get_customer_credit_balance(
    p_tenant_id   UUID,
    p_platform_code VARCHAR(50),
    p_as_of       TIMESTAMPTZ   -- "evaluate as of now" — a NOW candidate for step 2 (DEFAULT now())
)
RETURNS BIGINT AS $$
DECLARE
    v_batch RECORD;
    v_event RECORD;
    v_ids BIGINT[] := '{}';
    v_remaining BIGINT[] := '{}';
    v_expires TIMESTAMPTZ[] := '{}';
    v_started TIMESTAMPTZ[] := '{}';   -- FIX: track each batch's purchase time
    v_need BIGINT;
    v_take BIGINT;
    i INT;
    v_balance BIGINT := 0;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR p_platform_code = '' THEN
        RAISE EXCEPTION 'tenant_id and platform_code are required' USING ERRCODE = 'ER001';
    END IF;

    FOR v_batch IN
        SELECT cpp.id AS batch_id, otp.credit_quantity AS granted,
               cpp.started_at AS started_at,
               cpp.started_at + (otp.duration || ' ' || otp.duration_uom)::interval AS expires_at
        FROM customer_pricing_plans cpp
        JOIN one_time_pricing_plans otp ON otp.id = cpp.one_time_pricing_plan_id
        WHERE cpp.tenant_id = p_tenant_id AND cpp.platform_code = p_platform_code
          AND otp.is_credit_system = true
          AND cpp.started_at <= p_as_of
        ORDER BY (cpp.started_at + (otp.duration || ' ' || otp.duration_uom)::interval) ASC,
                 cpp.started_at ASC
    LOOP
        v_ids := array_append(v_ids, v_batch.batch_id);
        v_remaining := array_append(v_remaining, v_batch.granted);
        v_expires := array_append(v_expires, v_batch.expires_at);
        v_started := array_append(v_started, v_batch.started_at);   -- FIX
    END LOOP;

    FOR v_event IN
        SELECT consumed_at, credits_consumed
        FROM credit_consumptions
        WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code AND consumed_at <= p_as_of
        ORDER BY consumed_at ASC
    LOOP
        v_need := v_event.credits_consumed;
        i := 1;
        WHILE v_need > 0 AND i <= COALESCE(array_length(v_ids, 1), 0) LOOP
            -- FIX: a consumption may only draw from a batch that was already
            -- purchased at/before the consumption time (v_started[i] <= consumed_at),
            -- in addition to the existing not-yet-expired check.
            IF v_remaining[i] > 0
               AND v_started[i] <= v_event.consumed_at
               AND v_expires[i] > v_event.consumed_at THEN
                v_take := LEAST(v_need, v_remaining[i]);
                v_remaining[i] := v_remaining[i] - v_take;
                v_need := v_need - v_take;
            END IF;
            i := i + 1;
        END LOOP;
    END LOOP;

    FOR i IN 1..COALESCE(array_length(v_ids, 1), 0) LOOP
        IF v_expires[i] > p_as_of THEN
            v_balance := v_balance + v_remaining[i];
        END IF;
    END LOOP;

    RETURN v_balance;
END;
$$ LANGUAGE plpgsql;
