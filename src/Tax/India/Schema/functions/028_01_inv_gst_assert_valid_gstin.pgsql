-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_gst_assert_valid_gstin — split from Gst/028_gst_party.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: party validation + state resolution
--   PORT of `Dto/PartyInput.php` (validation) + `Lib/AddressSnapshotter.php`
--   (resolveStateCode / effectiveRegistrationStatus).
--
-- registration_status is a TEXT enum: 'regular' | 'composition' | 'unregistered'.
-- role is 'seller' | 'buyer'. All the DTO-construction validation the PHP did is
-- here (all business logic lives in SQL, none in PHP).
--
--   ER027  GSTIN is not a well-formed 15-char GSTIN                 -> 400
--   ER028  GSTIN state prefix is not a real CBIC-assigned code      -> 400
--   ER029  registration_status/gstin combination is contradictory   -> 400

-- Reject (never substitute) a malformed GSTIN, or one whose 2-digit state prefix
-- is syntactically plausible but not assigned. Mirrors PartyInput::assertValidGstinShape.

CREATE OR REPLACE FUNCTION inv_gst_assert_valid_gstin(p_gstin TEXT, p_party_label TEXT)
RETURNS VOID AS $$
DECLARE
    v_prefix TEXT;
BEGIN
    IF p_gstin !~ inv_gst_config_text('gstin_shape_regex') THEN
        RAISE EXCEPTION 'The %''s GSTIN "%" is not a well-formed 15-character GSTIN (expected e.g. "29AAACX1234C1ZP").',
            p_party_label, p_gstin USING ERRCODE = 'ER027';
    END IF;
    v_prefix := substr(p_gstin, 1, 2);
    IF inv_gst_resolve_state(v_prefix) IS NULL THEN
        RAISE EXCEPTION 'The %''s GSTIN "%" starts with "%", which is not a real CBIC-assigned GST state/UT code.',
            p_party_label, p_gstin, v_prefix USING ERRCODE = 'ER028';
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;
