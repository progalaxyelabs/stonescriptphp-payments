-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: _inv_series_create
--
-- Defines a numbering series for an issuer. Returns the series id.
--
-- Rejected at CREATION (never at the thousandth invoice):
--   * a series whose LONGEST possible number (full FY label when fy_reset, full width of
--     nines) exceeds the configured maximum length (16) or leaves the allowed charset;
--   * a test series whose prefix does not start with TEST, or a live series whose does;
--   * a head (prefix || sep) that is a prefix of another series' head, or vice versa:
--     two such series could mint the same string.
-- Idempotent: re-running with a DEFINITION identical to the existing series of that
-- code returns its id; a different definition under an existing code is refused.
CREATE OR REPLACE FUNCTION _inv_series_create(
    p_series_code TEXT,
    p_issuer_code TEXT,
    p_kind        TEXT,
    p_mode        TEXT,
    p_prefix      TEXT,
    p_sep         TEXT,
    p_width       INTEGER,
    p_fy_reset    BOOLEAN,
    p_actor       TEXT
) RETURNS BIGINT AS $$
DECLARE
    v_issuer   inv_issuers;
    v_existing inv_series;
    v_head     TEXT;
    v_id       BIGINT;
    v_clash    TEXT;
BEGIN
    IF p_actor IS NULL OR btrim(p_actor) = '' THEN
        RAISE EXCEPTION '_inv_series_create: actor is required.' USING ERRCODE = 'PY014';
    END IF;
    IF p_prefix IS NULL OR p_prefix = '' OR p_sep IS NULL OR p_width IS NULL OR p_width < 1 OR p_fy_reset IS NULL THEN
        RAISE EXCEPTION '_inv_series_create: prefix, sep, width and fy_reset are all required.' USING ERRCODE = 'PY014';
    END IF;

    SELECT * INTO v_issuer FROM inv_issuers WHERE issuer_code = p_issuer_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'issuer "%" does not exist.', p_issuer_code USING ERRCODE = 'PY010';
    END IF;

    SELECT * INTO v_existing FROM inv_series WHERE series_code = p_series_code;
    IF FOUND THEN
        IF v_existing.issuer_id = v_issuer.id AND v_existing.kind = p_kind AND v_existing.mode = p_mode
           AND v_existing.prefix = p_prefix AND v_existing.sep = p_sep
           AND v_existing.width = p_width AND v_existing.fy_reset = p_fy_reset THEN
            RETURN v_existing.id;
        END IF;
        RAISE EXCEPTION 'series "%" already exists with a different definition; a series definition is immutable - create a new series instead.', p_series_code
            USING ERRCODE = 'PY014';
    END IF;

    -- longest possible number: full FY label (always 5 chars, 'YY-YY') + full width of nines
    PERFORM inv_number_assert_lawful(
        p_prefix || p_sep || CASE WHEN p_fy_reset THEN '99-99' || p_sep ELSE '' END || repeat('9', p_width));

    v_head := _inv_series_head(p_prefix, p_sep);
    SELECT s.series_code INTO v_clash
      FROM inv_series s
     WHERE left(_inv_series_head(s.prefix, s.sep), length(v_head)) = v_head
        OR left(v_head, length(_inv_series_head(s.prefix, s.sep))) = _inv_series_head(s.prefix, s.sep)
     LIMIT 1;
    IF v_clash IS NOT NULL THEN
        RAISE EXCEPTION 'series head "%" overlaps series "%": two series could mint the same number.', v_head, v_clash
            USING ERRCODE = 'PY014';
    END IF;

    INSERT INTO inv_series (series_code, issuer_id, kind, mode, prefix, sep, width, fy_reset, created_by)
    VALUES (p_series_code, v_issuer.id, p_kind, p_mode, p_prefix, p_sep, p_width, p_fy_reset, p_actor)
    RETURNING id INTO v_id;
    RETURN v_id;
EXCEPTION
    WHEN check_violation THEN
        RAISE EXCEPTION '_inv_series_create: invalid series definition (%).', SQLERRM USING ERRCODE = 'PY014';
END;
$$ LANGUAGE plpgsql;
