-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: _inv_issuer_upsert
--
-- Creates or updates a seller of record, keyed by issuer_code. Returns the id.
--   * Ownership (platform_code, tenant_id) is fixed at creation; changing it is refused.
--   * Updating a profile never rewrites an issued invoice (invoices snapshot the issuer).
--   * Clearing is_placeholder (making the issuer LIVE-capable) requires a complete
--     identity: a valid GSTIN for a registered/composition seller, and a state code.
--     An unregistered seller needs no GSTIN, but still a state code (place of supply).
CREATE OR REPLACE FUNCTION _inv_issuer_upsert(
    p_issuer_code         TEXT,
    p_platform_code       VARCHAR(50),
    p_tenant_id           UUID,
    p_legal_name          TEXT,
    p_registration_status TEXT,
    p_gstin               TEXT,
    p_state_code          TEXT,
    p_address             TEXT,
    p_is_placeholder      BOOLEAN,
    p_actor               TEXT
) RETURNS BIGINT AS $$
DECLARE
    v_existing inv_issuers;
    v_id       BIGINT;
BEGIN
    IF p_actor IS NULL OR btrim(p_actor) = '' THEN
        RAISE EXCEPTION '_inv_issuer_upsert: actor is required.' USING ERRCODE = 'PY014';
    END IF;
    IF p_platform_code IS NULL OR btrim(p_platform_code) = '' THEN
        RAISE EXCEPTION '_inv_issuer_upsert: platform_code is required.' USING ERRCODE = 'PY014';
    END IF;
    IF p_is_placeholder IS NULL THEN
        RAISE EXCEPTION '_inv_issuer_upsert: is_placeholder must be stated explicitly (true until the real legal identity is known).'
            USING ERRCODE = 'PY014';
    END IF;

    IF NOT p_is_placeholder THEN
        IF p_registration_status IN ('regular', 'composition') THEN
            IF p_gstin IS NULL OR btrim(p_gstin) = '' THEN
                RAISE EXCEPTION 'issuer "%": a % seller needs a GSTIN before it can be made live.', p_issuer_code, p_registration_status
                    USING ERRCODE = 'PY014';
            END IF;
            PERFORM inv_gst_assert_valid_gstin(p_gstin, 'issuer');
        END IF;
        IF p_state_code IS NULL THEN
            RAISE EXCEPTION 'issuer "%": a state code is required before it can be made live (place of supply is never guessed).', p_issuer_code
                USING ERRCODE = 'PY014';
        END IF;
    END IF;

    SELECT * INTO v_existing FROM inv_issuers WHERE issuer_code = p_issuer_code FOR UPDATE;
    IF FOUND THEN
        IF v_existing.platform_code IS DISTINCT FROM p_platform_code
           OR v_existing.tenant_id IS DISTINCT FROM p_tenant_id THEN
            RAISE EXCEPTION 'issuer "%" already belongs to another owner; ownership cannot be changed.', p_issuer_code
                USING ERRCODE = 'PY014';
        END IF;
        UPDATE inv_issuers SET
            legal_name = p_legal_name, registration_status = p_registration_status, gstin = p_gstin,
            state_code = p_state_code, address = p_address, is_placeholder = p_is_placeholder,
            updated_at = now(), updated_by = p_actor
         WHERE id = v_existing.id;
        RETURN v_existing.id;
    END IF;

    INSERT INTO inv_issuers (issuer_code, platform_code, tenant_id, legal_name, registration_status, gstin,
                             state_code, address, is_placeholder, created_by, updated_by)
    VALUES (p_issuer_code, p_platform_code, p_tenant_id, p_legal_name, p_registration_status, p_gstin,
            p_state_code, p_address, p_is_placeholder, p_actor, p_actor)
    RETURNING id INTO v_id;
    RETURN v_id;
EXCEPTION
    WHEN check_violation THEN
        RAISE EXCEPTION '_inv_issuer_upsert: invalid issuer definition (%).', SQLERRM USING ERRCODE = 'PY014';
END;
$$ LANGUAGE plpgsql;
