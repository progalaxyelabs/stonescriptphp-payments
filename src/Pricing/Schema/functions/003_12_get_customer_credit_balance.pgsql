-- package: progalaxyelabs/stonescriptphp-payments (merged from stonescriptphp-payments + stonescriptphp-invoice) v0.1.0
-- stonescriptphp-payments :: Pricing :: functions :: get_customer_credit_balance — RESTORED
-- at the 2026-09-22 merge. The 2026-09-14 SCOPE->BUCKET layout migration split
-- 003_pricing_functions.pgsql into per-object files but DROPPED this function's
-- original (pre-031-fix) definition entirely — 031_01_get_customer_credit_balance.pgsql
-- (a later CREATE OR REPLACE "fix", by numeric-prefix design loading AFTER the Tax/India
-- group) was left as the ONLY definition, which starved every earlier-numbered test
-- (014_test_credit_balance.psql, prefix < 031) of the function entirely on a fresh DB.
-- Restored here verbatim from the last committed monolithic source
-- (stonescriptphp-invoice git fe5c7f2, 003_pricing_functions.pgsql:453-508), preserving
-- the ORIGINAL (intentionally not-yet-fixed) FIFO body — 031 still CREATE OR REPLACEs
-- this with the purchase-time-guard fix later in load order, exactly as designed; this
-- file's only job is to make the base function exist from 003's position onward, same as
-- every other adopting platform's actual deploy order always required.
--
-- Identity columns updated to tenant_id UUID + platform_code VARCHAR(50) (matching
-- the auth service's tenant_memberships shape 1:1) per the 2026-09-22 identity merge —
-- no other behavior changed from the original body.

-- Balance as of any given date, computed fresh from raw facts every time —
-- never a stored running total. Simulates true FIFO depletion in chronological
-- order: each credit-pack purchase (a customer_pricing_plans row against a
-- credit-system one_time_pricing_plan) opens a batch of credit_quantity
-- credits expiring at started_at + duration/duration_uom; each consumption
-- event draws from the EARLIEST-EXPIRING still-open batch first. A batch
-- that expires with credits left over forfeits them — no refund, they are
-- simply excluded from the balance the moment p_as_of passes that batch's
-- own expiry, whether or not they were ever touched.
CREATE OR REPLACE FUNCTION get_customer_credit_balance(p_tenant_id UUID, p_platform_code VARCHAR(50), p_as_of TIMESTAMPTZ)
RETURNS BIGINT AS $$
DECLARE
    v_batch RECORD;
    v_event RECORD;
    v_ids BIGINT[] := '{}';
    v_remaining BIGINT[] := '{}';
    v_expires TIMESTAMPTZ[] := '{}';
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
            IF v_remaining[i] > 0 AND v_expires[i] > v_event.consumed_at THEN
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
