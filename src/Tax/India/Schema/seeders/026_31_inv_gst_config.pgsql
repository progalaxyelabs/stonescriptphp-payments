-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: seeders :: inv_gst_config — split from Gst/026_gst_config_and_slabs.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: GST config values + rate slabs — DATA behind the
-- engine's derivations (the "every VALUE is DATA" principle).
--
-- Every business VALUE the PHP kept as a class constant lives here as a ROW:
-- the invoice-number length cap and charset, the rounding-adjustment range,
-- the GSTIN shape regex, the exemption legend / document titles / no-credit note,
-- and the recognised GST rate slab set. Functions read these; none is a literal in a
-- function body.

INSERT INTO inv_gst_config (config_key, config_value, note) VALUES
    ('invoice_number_max_length', '16',
        'Invoice number: at most sixteen characters.'),
    ('invoice_number_charset_regex', '^[A-Za-z0-9/ -]+$',
        'Invoice number charset: alphanumeric plus "-", "/", and a literal space.'),
    ('round_off_max_minor_units', '10000',
        'Rounding-adjustment range is -99.99..+99.99 rupees = strictly < 10000 paisa.'),
    ('gstin_shape_regex', '^\d{2}[A-Z]{5}\d{4}[A-Z][0-9A-Z]Z[0-9A-Z]$',
        'The 15-character GSTIN shape (review CRITICAL 1).'),
    ('composition_legend', 'Composition taxable person, not eligible to collect tax on supplies',
        'Legend for a composition-scheme bill_of_supply.'),
    ('no_itc_note', 'No tax has been charged on this document. No input tax credit is available against it.',
        'Printed on every no-tax (bill_of_supply) document (review W6a).'),
    ('title_tax_invoice', 'Tax Invoice', 'Caption for a tax invoice.'),
    ('title_bill_of_supply', 'Bill of Supply', 'Caption for a bill of supply (registered/composition seller).'),
    ('title_unregistered_invoice', 'Invoice',
        'An unregistered seller''s document is a plain commercial invoice, not a tax-caption document.'),
    ('legacy_rate_slabs', '0.12,0.28',
        'Slabs still accepted for historical documents but retired for new ones (GST 2.0). CA to confirm.'),
    ('issue_date_window_days_live', '0',
        'A LIVE series-numbered invoice must be dated today (IST) +/- this many days: 0 = the current IST calendar day only. Live documents are dated when they are issued; history comes in through the explicit-number import path, which is exempt.'),
    ('issue_date_window_days_test', '7',
        'The same window for TEST series, wider so sandbox flows and demos can post-date or back-date. A test document carries a TEST number and never reaches the books.');
