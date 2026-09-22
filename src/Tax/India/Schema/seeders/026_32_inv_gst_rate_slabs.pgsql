-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: seeders :: inv_gst_rate_slabs — split from Gst/026_gst_config_and_slabs.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: GST config values + rate slabs — DATA behind the
-- engine's derivations (the "every VALUE is DATA" principle).
--
-- Every business VALUE the PHP kept as a class constant lives here as a ROW:
-- the invoice-number length cap and charset, the rounding-adjustment range,
-- the GSTIN shape regex, the exemption legend / document titles / no-credit note,
-- and the recognised GST rate slab set. Functions read these; none is a literal in a
-- function body.

INSERT INTO inv_gst_rate_slabs (rate) VALUES
    (0), (0.0025), (0.03), (0.05), (0.12), (0.18), (0.28);
