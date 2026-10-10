-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _pay_order_spec_buyer
--
-- The buyer party of an order's invoice_spec. The spec (JSON) shape is documented on
-- _pay_order_spec_lines. Missing fields are NULL; the tax engine validates them.
CREATE OR REPLACE FUNCTION _pay_order_spec_buyer(p_spec JSONB)
RETURNS inv_party_input AS $$
    SELECT ROW(b->>'legal_name', b->>'gstin', 'buyer', b->>'registration_status', b->>'address_state', b->>'state_code')::inv_party_input
      FROM (SELECT p_spec->'buyer' AS b) s;
$$ LANGUAGE sql IMMUTABLE;
