-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_gst_config_text — split from Gst/026_gst_config_and_slabs.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: GST config values + rate slabs — DATA behind the
-- engine's derivations (the "every VALUE is DATA" principle).
--
-- Every business VALUE the PHP kept as a class constant lives here as a ROW:
-- the invoice-number length cap and charset, the rounding-adjustment range,
-- the GSTIN shape regex, the exemption legend / document titles / no-credit note,
-- and the recognised GST rate slab set. Functions read these; none is a literal in a
-- function body.

CREATE OR REPLACE FUNCTION inv_gst_config_text(p_key TEXT)
RETURNS TEXT AS $$
DECLARE
    v TEXT;
BEGIN
    SELECT config_value INTO v FROM inv_gst_config WHERE config_key = p_key;
    IF v IS NULL THEN
        RAISE EXCEPTION 'inv_gst_config key "%" is not configured', p_key USING ERRCODE = 'ER006';
    END IF;
    RETURN v;
END;
$$ LANGUAGE plpgsql STABLE;
