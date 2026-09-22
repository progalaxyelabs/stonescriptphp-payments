-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_gst_validate_party — split from Gst/028_gst_party.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

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

-- Full PartyInput construction-time validation: GSTIN shape/prefix (whenever
-- present, regardless of declared status) + registration_status/gstin
-- consistency (role-worded messages, review W4). A null status is allowed here
-- (a buyer's is optional; a seller's null is caught later by the engine).

CREATE OR REPLACE FUNCTION inv_gst_validate_party(p_role TEXT, p_registration_status TEXT, p_gstin TEXT)
RETURNS VOID AS $$
DECLARE
    v_present BOOLEAN := p_gstin IS NOT NULL AND btrim(p_gstin) <> '';
    v_label   TEXT    := CASE WHEN p_role = 'seller' THEN 'seller' ELSE 'buyer' END;
BEGIN
    IF v_present THEN
        PERFORM inv_gst_assert_valid_gstin(btrim(p_gstin), v_label);
    END IF;

    IF p_registration_status IS NULL THEN
        RETURN;
    END IF;

    IF p_registration_status = 'regular' THEN
        IF NOT v_present THEN
            IF p_role = 'seller' THEN
                RAISE EXCEPTION 'Add your GSTIN in Settings before issuing a tax invoice.' USING ERRCODE = 'ER029';
            ELSE
                RAISE EXCEPTION 'The buyer''s GSTIN is required — a ''regular'' buyer must carry a GSTIN, or leave registration_status unset if it is not known.'
                    USING ERRCODE = 'ER029';
            END IF;
        END IF;
    ELSIF p_registration_status = 'composition' THEN
        IF NOT v_present THEN
            RAISE EXCEPTION 'A ''composition'' % is registered and must carry a GSTIN — registration_status/gstin combination is contradictory.', v_label
                USING ERRCODE = 'ER029';
        END IF;
    ELSIF p_registration_status = 'unregistered' THEN
        IF v_present THEN
            RAISE EXCEPTION 'An ''unregistered'' % must not carry a GSTIN — registration_status/gstin combination is contradictory.', v_label
                USING ERRCODE = 'ER029';
        END IF;
    ELSE
        RAISE EXCEPTION 'Unknown registration_status "%" (expected regular|composition|unregistered).', p_registration_status
            USING ERRCODE = 'ER029';
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;
