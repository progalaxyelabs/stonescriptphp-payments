-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_gst_is_allowed_rate — split from Gst/026_gst_config_and_slabs.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: GST config values + rate slabs — DATA behind the
-- engine's derivations (the "every VALUE is DATA" principle).
--
-- Every business VALUE the PHP kept as a class constant lives here as a ROW:
-- the invoice-number length cap and charset, the rounding-adjustment range,
-- the GSTIN shape regex, the exemption legend / document titles / no-credit note,
-- and the recognised GST rate slab set. Functions read these; none is a literal in a
-- function body.

CREATE OR REPLACE FUNCTION inv_gst_is_allowed_rate(p_rate NUMERIC)
RETURNS BOOLEAN AS $$
    SELECT EXISTS (SELECT 1 FROM inv_gst_rate_slabs WHERE rate = p_rate);
$$ LANGUAGE sql STABLE;
