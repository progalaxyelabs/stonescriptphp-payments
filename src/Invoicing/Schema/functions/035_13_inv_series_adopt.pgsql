-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: _inv_series_adopt
--
-- Continues an EXISTING numbering series: sets the counter of (series, fy) to the
-- last serial already used elsewhere (a previous system, or numbers already stored
-- in inv_invoices), so the next library-issued number is exactly last + 1. Nothing
-- is ever renumbered.
--
--   * Monotonic: refuses (PY018) to move a counter backwards; the same value is a no-op.
--   * Refuses (PY018) a value below a serial that already exists in inv_invoices for
--     this series and FY, which would re-issue an existing number.
--   * Mandatory evidence_ref and actor; every move is appended to inv_series_adoptions.
--   * p_fy_label must be NULL/'' for a series without fy_reset, and 'YY-YY' for one with.
--   * The FY label is validated: 'YY-YY' with the second year exactly the first + 1, and within one
--     year of the current financial year (a typo such as 26-28, 2627 or 99-00 is refused, PY014).
--   * p_dry_run = true changes nothing and reports what WOULD happen (o_applied = false).
--   * It locks the counter row, so it queues behind and ahead of concurrent issuance correctly.
-- Returns the previous and the new last number, and whether the counter was moved.
CREATE OR REPLACE FUNCTION _inv_series_adopt(
    p_series_code    TEXT,
    p_fy_label       TEXT,
    p_last_used      BIGINT,
    p_evidence_ref   TEXT,
    p_actor          TEXT,
    p_adopted_at     TIMESTAMPTZ DEFAULT now(),
    p_dry_run        BOOLEAN DEFAULT false
) RETURNS TABLE (o_previous_last BIGINT, o_new_last BIGINT, o_applied BOOLEAN) AS $$
DECLARE
    v_series   inv_series;
    v_fy       TEXT;
    v_prev     BIGINT;
    v_head     TEXT;
    v_max_used BIGINT;
    v_cur_fy   INTEGER;
    v_y1       INTEGER;
    v_y2       INTEGER;
BEGIN
    IF p_evidence_ref IS NULL OR btrim(p_evidence_ref) = '' OR p_actor IS NULL OR btrim(p_actor) = '' THEN
        RAISE EXCEPTION '_inv_series_adopt: evidence_ref and actor are mandatory.' USING ERRCODE = 'PY014';
    END IF;
    IF p_last_used IS NULL OR p_last_used < 0 THEN
        RAISE EXCEPTION '_inv_series_adopt: last_used must be zero or a positive integer.' USING ERRCODE = 'PY014';
    END IF;

    SELECT * INTO v_series FROM inv_series WHERE series_code = p_series_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'series "%" does not exist.', p_series_code USING ERRCODE = 'PY010';
    END IF;

    v_fy := COALESCE(p_fy_label, '');
    IF v_series.fy_reset THEN
        IF v_fy !~ '^[0-9]{2}-[0-9]{2}$' THEN
            RAISE EXCEPTION 'series "%" resets every financial year: give the FY label (e.g. 26-27).', p_series_code
                USING ERRCODE = 'PY014';
        END IF;
        v_y1 := substr(v_fy, 1, 2)::int;
        v_y2 := substr(v_fy, 4, 2)::int;
        v_cur_fy := substr(_inv_in_fy_label(now()), 1, 2)::int;
        IF v_y2 <> (v_y1 + 1) % 100 THEN
            RAISE EXCEPTION 'FY label "%" is not a financial year: the second year must be the first + 1.', v_fy USING ERRCODE = 'PY014';
        END IF;
        IF least(abs(v_y1 - v_cur_fy), 100 - abs(v_y1 - v_cur_fy)) > 1 THEN
            RAISE EXCEPTION 'FY label "%" is more than one year from the current financial year (%): refusing to adopt it.',
                v_fy, _inv_in_fy_label(now()) USING ERRCODE = 'PY014';
        END IF;
    ELSIF v_fy <> '' THEN
        RAISE EXCEPTION 'series "%" has one continuous counter: the FY label must be empty.', p_series_code
            USING ERRCODE = 'PY014';
    END IF;
    IF p_last_used >= power(10, v_series.width)::BIGINT THEN
        RAISE EXCEPTION 'last_used % does not fit the series width %.', p_last_used, v_series.width USING ERRCODE = 'PY014';
    END IF;

    IF NOT p_dry_run THEN
        INSERT INTO inv_series_counter (series_id, fy_label, last_number)
        VALUES (v_series.id, v_fy, 0)
        ON CONFLICT (series_id, fy_label) DO NOTHING;
    END IF;

    SELECT c.last_number INTO v_prev
      FROM inv_series_counter c WHERE c.series_id = v_series.id AND c.fy_label = v_fy
      FOR UPDATE;
    v_prev := coalesce(v_prev, 0);

    IF p_last_used < v_prev THEN
        RAISE EXCEPTION 'series "%" (%): counter is at % - it can never move backwards (asked for %).',
            p_series_code, v_fy, v_prev, p_last_used USING ERRCODE = 'PY018';
    END IF;

    -- the highest serial already present for this series and FY in the invoice table
    v_head := v_series.prefix || v_series.sep || CASE WHEN v_series.fy_reset THEN v_fy || v_series.sep ELSE '' END;
    SELECT max(substr(i.invoice_number, length(v_head) + 1)::BIGINT) INTO v_max_used
      FROM inv_invoices i
     WHERE left(i.invoice_number, length(v_head)) = v_head
       AND substr(i.invoice_number, length(v_head) + 1) ~ '^[0-9]+$';
    IF v_max_used IS NOT NULL AND p_last_used < v_max_used THEN
        RAISE EXCEPTION 'series "%" (%): an invoice with serial % already exists - adopting % would re-issue an existing number.',
            p_series_code, v_fy, v_max_used, p_last_used USING ERRCODE = 'PY018';
    END IF;

    o_previous_last := v_prev;
    o_new_last := p_last_used;
    IF p_last_used = v_prev OR p_dry_run THEN
        o_applied := false;
        RETURN NEXT;     -- idempotent no-op, or a dry run: nothing moved, nothing logged
        RETURN;
    END IF;

    UPDATE inv_series_counter SET last_number = p_last_used, updated_at = p_adopted_at
     WHERE series_id = v_series.id AND fy_label = v_fy;
    INSERT INTO inv_series_adoptions (series_id, fy_label, previous_last, adopted_last, evidence_ref, adopted_by, adopted_at)
    VALUES (v_series.id, v_fy, v_prev, p_last_used, p_evidence_ref, p_actor, p_adopted_at);
    o_applied := true;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
