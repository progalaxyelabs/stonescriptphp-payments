-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _wlt_pack_create (INTERNAL; a platform's seed migration or an operator)
-- Creates a wallet pack, validated at creation: the pricing plan must exist and be active, credits positive, validity a pair (day | month | year).
CREATE OR REPLACE FUNCTION _wlt_pack_create(p_pricing_plan_id BIGINT, p_name TEXT, p_credits_milli BIGINT, p_validity_duration INTEGER, p_validity_uom TEXT, p_actor TEXT)
RETURNS BIGINT AS $$
DECLARE
    v_id BIGINT;
BEGIN
    IF p_name IS NULL OR btrim(p_name) = '' OR p_actor IS NULL OR btrim(p_actor) = '' THEN
        RAISE EXCEPTION '_wlt_pack_create: a name and an actor are required.' USING ERRCODE = 'PY070';
    END IF;
    IF p_credits_milli IS NULL OR p_credits_milli <= 0 THEN
        RAISE EXCEPTION '_wlt_pack_create: a pack must grant a positive number of milli-credits (got %).', p_credits_milli USING ERRCODE = 'ER013';
    END IF;
    IF (p_validity_duration IS NULL) <> (p_validity_uom IS NULL) OR (p_validity_duration IS NOT NULL AND (p_validity_duration <= 0 OR p_validity_uom NOT IN ('day', 'month', 'year'))) THEN
        RAISE EXCEPTION '_wlt_pack_create: validity is a positive duration with a unit (day | month | year), both or neither.' USING ERRCODE = 'PY070';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pricing_plans WHERE id = p_pricing_plan_id AND is_active AND NOT is_trial) THEN
        RAISE EXCEPTION '_wlt_pack_create: pricing plan % does not exist or is not active.', p_pricing_plan_id USING ERRCODE = 'ER015';
    END IF;
    INSERT INTO wlt_packs (pricing_plan_id, name, credits_milli, validity_duration, validity_uom, created_by)
    VALUES (p_pricing_plan_id, p_name, p_credits_milli, p_validity_duration, p_validity_uom, p_actor) RETURNING id INTO v_id;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql;
