-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: inv_series_gap_audit
--
-- Audits the books against the counters: for every series and financial year it lists every serial
-- that SHOULD exist and does not, plus any invoice beyond the counter. A healthy database returns no rows.
--
--   missing_serial   a serial between (what was adopted from elsewhere) + 1 and the counter that no invoice
--                    carries. Serials up to the highest adopted value are expected to live elsewhere, so
--                    they are not reported.
--   beyond_counter   an invoice whose serial is higher than the counter (the counter was moved back)
--
-- plpgsql, not sql, on purpose: the gateway deploys functions BEFORE it runs the migration that adds the
-- numbering columns to an existing inv_invoices, and a LANGUAGE sql body is validated at creation time.
--
-- Run it on a schedule and after every cutover; an unexplained row is an audit finding.
CREATE OR REPLACE FUNCTION inv_series_gap_audit(p_series_code TEXT DEFAULT NULL)
RETURNS TABLE (o_series_code TEXT, o_fy_label TEXT, o_finding TEXT, o_serial BIGINT) AS $$
BEGIN
    RETURN QUERY
    WITH ctr AS (
        SELECT s.id AS series_id, s.series_code, c.fy_label, c.last_number,
               coalesce((SELECT max(a.adopted_last) FROM inv_series_adoptions a WHERE a.series_id = s.id AND a.fy_label = c.fy_label), 0) AS adopted
          FROM inv_series_counter c JOIN inv_series s ON s.id = c.series_id
         WHERE p_series_code IS NULL OR s.series_code = p_series_code
    )
    SELECT ctr.series_code, ctr.fy_label, 'missing_serial', g::bigint
      FROM ctr, LATERAL generate_series(ctr.adopted + 1, ctr.last_number) g
     WHERE NOT EXISTS (SELECT 1 FROM inv_invoices i WHERE i.series_id = ctr.series_id AND i.fy_label = ctr.fy_label AND i.number_seq = g)
    UNION ALL
    SELECT ctr.series_code, ctr.fy_label, 'beyond_counter', i.number_seq
      FROM ctr JOIN inv_invoices i ON i.series_id = ctr.series_id AND i.fy_label = ctr.fy_label AND i.number_seq > ctr.last_number
    ORDER BY 1, 2, 4;
END;
$$ LANGUAGE plpgsql STABLE;
