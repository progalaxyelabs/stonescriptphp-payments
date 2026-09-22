-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: tables :: inv_gst_rate_slabs — split from Gst/026_gst_config_and_slabs.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: GST config values + rate slabs — DATA behind the
-- engine's derivations (the "every VALUE is DATA" principle).
--
-- Every business VALUE the PHP kept as a class constant lives here as a ROW:
-- the invoice-number length cap and charset, the rounding-adjustment range,
-- the GSTIN shape regex, the exemption legend / document titles / no-credit note,
-- and the recognised GST rate slab set. Functions read these; none is a literal in a
-- function body.

-- The recognised GST rate slab set (review W1) — DATA. An 18 typed where 0.18 was
-- meant is a 1800% overcharge; gst_rate is validated against this closed set
-- unless a caller explicitly opts into allow_unlisted_rate for a future slab.

CREATE TABLE inv_gst_rate_slabs (
    rate    NUMERIC PRIMARY KEY
);
