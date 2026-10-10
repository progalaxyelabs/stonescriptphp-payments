-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: tables :: pay_config
--
-- Operational settings of the payments core, as DATA (never literals in a function body). Read through
-- _pay_config_int(). Seeded by src/Core/Schema/seeders/051_31_pay_config.pgsql; a deployment changes a value
-- with a plain UPDATE (the seeder / _pay_ensure_reference_data never overwrite an existing row).
CREATE TABLE pay_config (
    config_key   TEXT PRIMARY KEY,
    config_value TEXT NOT NULL,
    note         TEXT
);
