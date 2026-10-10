-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: trigger inv_series_guard (inv_numbering_guard, 035_18)
CREATE OR REPLACE TRIGGER inv_series_guard
    BEFORE UPDATE OR DELETE ON inv_series
    FOR EACH ROW EXECUTE FUNCTION inv_numbering_guard();
