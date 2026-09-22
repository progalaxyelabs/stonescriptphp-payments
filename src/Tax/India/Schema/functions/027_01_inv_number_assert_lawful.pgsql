-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_number_assert_lawful — split from Gst/027_gst_number_formatter.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

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

-- Validate an already-assembled number. Mirrors NumberFormatter::assertLawful.

CREATE OR REPLACE FUNCTION inv_number_assert_lawful(p_number TEXT)
RETURNS VOID AS $$
DECLARE
    v_max BIGINT := inv_gst_config_int('invoice_number_max_length');
BEGIN
    IF p_number = '' OR p_number IS NULL THEN
        RAISE EXCEPTION 'An invoice number cannot be empty.' USING ERRCODE = 'ER040';
    END IF;
    IF length(p_number) > v_max THEN
        RAISE EXCEPTION 'Invoice number "%" is % characters — the configured maximum is %.',
            p_number, length(p_number), v_max USING ERRCODE = 'ER040';
    END IF;
    IF p_number !~ inv_gst_config_text('invoice_number_charset_regex') THEN
        RAISE EXCEPTION 'Invoice number "%" contains a character outside the configured allowed set (alphanumeric, "-", "/", " ").',
            p_number USING ERRCODE = 'ER040';
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;
