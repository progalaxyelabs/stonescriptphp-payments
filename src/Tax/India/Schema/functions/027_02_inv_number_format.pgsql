-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_number_format — split from Gst/027_gst_number_formatter.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: invoice-number assembly + length/charset validation
--   PORT of `Lib/NumberFormatter.php`.
--
-- Phase 1 is FORMATTING only — no counter, no persistence, no allocation (that
-- is Phase 2's inv_issue_invoice, not built anywhere yet). The caller supplies
-- the sequence number; these functions assemble it and enforce the 16-char /
-- charset cap, reading both from inv_gst_config (026).
--
--   ER040  assembled/supplied invoice number fails the length/charset rule   -> 400
--   ER041  seq/seqWidth out of range                                         -> 400

-- Assemble prefix + zero-padded sequence, then assert lawful.
-- Mirrors NumberFormatter::format.

CREATE OR REPLACE FUNCTION inv_number_format(p_prefix TEXT, p_seq INTEGER, p_seq_width INTEGER)
RETURNS TEXT AS $$
DECLARE
    v_number TEXT;
BEGIN
    IF p_seq < 1 THEN
        RAISE EXCEPTION 'seq must be a positive integer — the first lawful serial is 1.' USING ERRCODE = 'ER041';
    END IF;
    IF p_seq_width < 1 THEN
        RAISE EXCEPTION 'seqWidth must be at least 1.' USING ERRCODE = 'ER041';
    END IF;
    v_number := p_prefix || lpad(p_seq::TEXT, p_seq_width, '0');
    PERFORM inv_number_assert_lawful(v_number);
    RETURN v_number;
END;
$$ LANGUAGE plpgsql STABLE;
