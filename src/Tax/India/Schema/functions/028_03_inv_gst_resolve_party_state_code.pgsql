-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_gst_resolve_party_state_code — split from Gst/028_gst_party.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

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

-- Resolve a party's effective 2-digit state code. Mirrors
-- AddressSnapshotter::resolveStateCode — when a GSTIN is present it is the ONLY
-- source (CRITICAL 1, no fallthrough); state_code/address_state are consulted
-- only for a party carrying no GSTIN.

CREATE OR REPLACE FUNCTION inv_gst_resolve_party_state_code(p_gstin TEXT, p_state_code TEXT, p_address_state TEXT)
RETURNS TEXT AS $$
BEGIN
    IF p_gstin IS NOT NULL AND btrim(p_gstin) <> '' THEN
        RETURN inv_gst_resolve_state(substr(btrim(p_gstin), 1, 2));
    END IF;
    IF p_state_code IS NOT NULL AND btrim(p_state_code) <> '' THEN
        RETURN inv_gst_resolve_state(p_state_code);
    END IF;
    RETURN inv_gst_resolve_state(p_address_state);
END;
$$ LANGUAGE plpgsql STABLE;
