-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: _inv_series_allocate
--
-- The ONLY allocator of statutory serials. Hands out the next number of a series
-- for a document date, GAPLESSLY:
--
--   * It increments inv_series_counter under the counter row's lock and returns
--     the number to its caller, which must use it in the SAME transaction (that is
--     what inv_issue_invoice and the draft->issued edge do). If that transaction
--     rolls back, the increment rolls back with it: the number is not burned.
--   * Concurrent callers on one series serialise on that row lock; each gets the
--     next number exactly once. (A sequence is never used: it would leak on rollback.)
--   * Per financial year when the series has fy_reset: the first allocation on or
--     after 1 April (IST) starts that year's counter at 1; otherwise the one counter
--     continues.
--
-- Refuses (never guesses):
--   PY012 the mode is missing, or differs from the series' mode - a test-mode
--         document can never draw a live number, nor a live one a test number;
--   PY013 a LIVE series whose issuer is still a placeholder;
--   PY011 an inactive series, or one of another kind;
--   PY010 an unknown series;
--   PY017 a counter that ran out of serials, or one that is behind a number that
--         already exists (adopt the series first - see _inv_series_adopt).
--
-- NOT directly callable: it refuses (PY041) unless the transaction was flagged by an issuing function
-- (inv_issue_invoice / inv_transition_invoice_status set pay.issuing for their own transaction), so no
-- caller can burn a serial without issuing a document. Audit the books with inv_series_gap_audit().
--
-- The document date is an explicit argument. It decides the FY, and it must lie within the window of now() measured in IST
-- CALENDAR DAYS (PY042): inv_gst_config 'issue_date_window_days_live' (default 0 = today only) for a live series,
-- 'issue_date_window_days_test' (default 7) for a test series. A mistyped or stale date can never put a number into the wrong
-- financial year or out of order across 1 April. Consequence worth stating: because a live document is dated the day it is
-- numbered, serial order IS date order (to the day) within a series; back-dated history enters through the explicit-number
-- import path, which does not allocate and is exempt (and is recognisable by series_id NULL). The two settings are data: a
-- deployment that really needs a wider live window sets it, knowingly.
-- SQLSTATEs added: PY041 direct allocation, PY042 document date outside the window.
CREATE OR REPLACE FUNCTION _inv_series_allocate(
    p_series_code TEXT,
    p_issue_at    TIMESTAMPTZ,
    p_mode        TEXT,
    p_kind        TEXT DEFAULT 'invoice'
) RETURNS TABLE (
    o_series_id      BIGINT,
    o_issuer_id      BIGINT,
    o_fy_label       TEXT,
    o_number_seq     BIGINT,
    o_invoice_number TEXT
) AS $$
DECLARE
    v_series inv_series;
    v_issuer inv_issuers;
    v_fy     TEXT;
    v_seq    BIGINT;
    v_number TEXT;
    v_window INTEGER;
BEGIN
    IF coalesce(current_setting('pay.issuing', true), '') <> 'on' THEN
        RAISE EXCEPTION '_inv_series_allocate cannot be called directly: serials are allocated only while issuing a document.'
            USING ERRCODE = 'PY041';
    END IF;
    IF p_mode IS NULL OR p_mode NOT IN ('live', 'test') THEN
        RAISE EXCEPTION 'cannot allocate a number: mode must be ''live'' or ''test'' (got "%"). The mode is never assumed.', p_mode
            USING ERRCODE = 'PY012';
    END IF;
    IF p_issue_at IS NULL THEN
        RAISE EXCEPTION 'cannot allocate a number without a document date (it decides the financial year).'
            USING ERRCODE = 'PY014';
    END IF;

    SELECT * INTO v_series FROM inv_series WHERE series_code = p_series_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'series "%" does not exist.', p_series_code USING ERRCODE = 'PY010';
    END IF;
    IF NOT v_series.is_active OR v_series.kind <> p_kind THEN
        RAISE EXCEPTION 'series "%" is not an active "%" series.', p_series_code, p_kind USING ERRCODE = 'PY011';
    END IF;
    IF v_series.mode <> p_mode THEN
        RAISE EXCEPTION 'series "%" is a % series but the document is in % mode: a test document never draws a live number and vice versa.',
            p_series_code, v_series.mode, p_mode USING ERRCODE = 'PY012';
    END IF;

    v_window := inv_gst_config_int(CASE WHEN v_series.mode = 'live' THEN 'issue_date_window_days_live' ELSE 'issue_date_window_days_test' END);
    IF abs((p_issue_at AT TIME ZONE 'Asia/Kolkata')::date - (now() AT TIME ZONE 'Asia/Kolkata')::date) > v_window THEN
        RAISE EXCEPTION 'document date % is more than % day(s) from today (IST) for a % series: refusing to number it (it would land in the wrong place in the series).',
            p_issue_at, v_window, v_series.mode USING ERRCODE = 'PY042';
    END IF;

    SELECT * INTO v_issuer FROM inv_issuers WHERE id = v_series.issuer_id;
    IF v_series.mode = 'live' AND v_issuer.is_placeholder THEN
        RAISE EXCEPTION 'live series "%" refuses to issue: its issuer "%" is still a placeholder (real legal identity not recorded).',
            p_series_code, v_issuer.issuer_code USING ERRCODE = 'PY013';
    END IF;

    v_fy := CASE WHEN v_series.fy_reset THEN _inv_in_fy_label(p_issue_at) ELSE '' END;

    INSERT INTO inv_series_counter (series_id, fy_label, last_number)
    VALUES (v_series.id, v_fy, 0)
    ON CONFLICT (series_id, fy_label) DO NOTHING;

    -- the row lock taken here is held to the end of the caller's transaction
    UPDATE inv_series_counter c
       SET last_number = c.last_number + 1, updated_at = now()
     WHERE c.series_id = v_series.id AND c.fy_label = v_fy
    RETURNING c.last_number INTO v_seq;

    v_number := _inv_series_format_number(v_series.prefix, v_series.sep, v_series.width, v_series.fy_reset, v_fy, v_seq);

    IF EXISTS (SELECT 1 FROM inv_invoices i WHERE i.invoice_number = v_number) THEN
        RAISE EXCEPTION 'series "%": number "%" already exists - the counter is behind the numbers already issued. Run _inv_series_adopt first.',
            p_series_code, v_number USING ERRCODE = 'PY017';
    END IF;

    o_series_id := v_series.id;
    o_issuer_id := v_series.issuer_id;
    o_fy_label := v_fy;
    o_number_seq := v_seq;
    o_invoice_number := v_number;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
