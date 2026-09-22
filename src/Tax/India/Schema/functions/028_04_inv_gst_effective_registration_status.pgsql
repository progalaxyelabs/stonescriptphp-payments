-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_gst_effective_registration_status — split from Gst/028_gst_party.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

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

-- Display-only effective status (never a tax decision). Mirrors
-- AddressSnapshotter::effectiveRegistrationStatus.

CREATE OR REPLACE FUNCTION inv_gst_effective_registration_status(p_registration_status TEXT, p_gstin TEXT)
RETURNS TEXT AS $$
    SELECT CASE
        WHEN p_registration_status IS NOT NULL THEN p_registration_status
        WHEN p_gstin IS NOT NULL AND btrim(p_gstin) <> '' THEN 'regular'
        ELSE 'unregistered'
    END;
$$ LANGUAGE sql IMMUTABLE;
