-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _ent_missing_mode, _ent_set_missing_mode (INTERNAL)
--
-- What a tenant with NO entitlement row gets, PER PLATFORM: a pay_config row 'ent_missing_mode:<platform>' ('read_only' | 'allow') overrides
-- the global default row 'ent_missing_mode'. A platform whose legacy middleware allowed missing subscriptions must keep that until it decides otherwise
-- (the cutover gate _ent_cutover_check compares the two). _ent_set_missing_mode is the audited operator write.
CREATE OR REPLACE FUNCTION _ent_missing_mode(p_platform VARCHAR(50)) RETURNS TEXT AS $$
    SELECT coalesce((SELECT config_value FROM pay_config WHERE config_key = 'ent_missing_mode:' || p_platform), _pay_config_text('ent_missing_mode'));
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION _ent_set_missing_mode(p_platform VARCHAR(50), p_mode TEXT, p_actor TEXT) RETURNS TEXT AS $$
BEGIN
    IF p_platform IS NULL OR btrim(p_platform) = '' OR p_mode IS NULL OR p_mode NOT IN ('read_only', 'allow') OR p_actor IS NULL OR btrim(p_actor) = '' THEN
        RAISE EXCEPTION '_ent_set_missing_mode: platform, mode (read_only|allow) and actor are required.' USING ERRCODE = 'PY060';
    END IF;
    INSERT INTO pay_config (config_key, config_value, note) VALUES ('ent_missing_mode:' || p_platform, p_mode, 'set by ' || p_actor || ' at ' || now()::text)
    ON CONFLICT (config_key) DO UPDATE SET config_value = EXCLUDED.config_value, note = EXCLUDED.note;
    RETURN p_mode;
END;
$$ LANGUAGE plpgsql;
