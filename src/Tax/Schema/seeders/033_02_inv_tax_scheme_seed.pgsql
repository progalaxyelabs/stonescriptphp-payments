-- package: progalaxyelabs/stonescriptphp-payments (merged from stonescriptphp-pay + stonescriptphp-invoice) v0.1.0
-- stonescriptphp-pay :: Tax :: seeders :: inv_tax_scheme — seed data, not code.
-- The one scheme this package ships an engine for today.

INSERT INTO inv_tax_scheme (billing_country_code, scheme_type, display_name, is_active, created_by)
VALUES ('IN', 'in_gst', 'India GST', TRUE, 'system:seed')
ON CONFLICT (billing_country_code) DO NOTHING;
