-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: pay_order_end_gateway_create
--
-- Releases the gateway-create lease early when the creator FAILED (the gateway call raised), so the client's retry with the
-- same key can take over at once instead of waiting for the lease to expire. A no-op once the gateway order is attached.
CREATE OR REPLACE FUNCTION pay_order_end_gateway_create(p_order_ref TEXT) RETURNS VOID AS $$
    UPDATE pay_orders SET gateway_create_lease_until = NULL WHERE order_ref = p_order_ref AND gateway_order_id IS NULL;
$$ LANGUAGE sql;
