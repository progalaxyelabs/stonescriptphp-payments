-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _pay_order_spec_lines
--
-- The invoice lines of an order's invoice_spec. The spec is a JSON object:
--   {
--     "buyer": {"legal_name": "...", "gstin": null, "registration_status": "unregistered",
--               "address_state": "Karnataka", "state_code": null},
--     "billing_country_code": "IN", "billing_state": "Karnataka",
--     "supply_type": "domestic",            -- domestic | export_lut | export_with_igst
--     "document_type": null,                -- null lets the engine choose from the seller's registration
--     "price_is_inclusive": false, "round_off": false,
--     "fx_rate": null, "amount_inr": null,  -- export invoices only
--     "due_days": 0,
--     "lines": [{"description": "...", "hsn_sac": "998314", "quantity": "1", "unit_price": "499.00",
--                "gst_rate": 0.18, "line_discount": null, "allow_unlisted_rate": false}]
--   }
CREATE OR REPLACE FUNCTION _pay_order_spec_lines(p_spec JSONB)
RETURNS inv_line_input[] AS $$
    SELECT array_agg(ROW(l->>'description', l->>'hsn_sac', l->>'quantity', l->>'unit_price',
                         (l->>'gst_rate')::numeric, l->>'line_discount',
                         coalesce((l->>'allow_unlisted_rate')::boolean, false))::inv_line_input ORDER BY o)
      FROM jsonb_array_elements(p_spec->'lines') WITH ORDINALITY AS t(l, o);
$$ LANGUAGE sql IMMUTABLE;
