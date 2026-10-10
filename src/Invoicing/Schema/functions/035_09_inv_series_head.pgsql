-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: _inv_series_head
--
-- The literal head of every number a series mints: prefix || sep. Two series whose
-- heads are prefixes of one another could mint the same string, so
-- _inv_series_create() refuses to create such a pair.
CREATE OR REPLACE FUNCTION _inv_series_head(p_prefix TEXT, p_sep TEXT)
RETURNS TEXT AS $$
    SELECT p_prefix || p_sep;
$$ LANGUAGE sql IMMUTABLE;
