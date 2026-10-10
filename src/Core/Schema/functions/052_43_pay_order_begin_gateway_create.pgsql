-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: pay_order_begin_gateway_create
--
-- A short lease so that, of several concurrent identical order requests, exactly ONE creates the gateway order. Returns
-- TRUE to the caller that now holds the lease (it must create the gateway order, then call
-- pay_order_attach_gateway_order, which also releases it); FALSE when the order already has a gateway order, or another
-- caller holds an unexpired lease (the caller should wait briefly for the winner's attach, then re-read). If the holder
-- dies, the lease simply expires and the next caller takes over. The gateway-side lookup by receipt (and PayPal's
-- request id) cover the remaining window where a holder created the gateway order but died before attaching it.
CREATE OR REPLACE FUNCTION pay_order_begin_gateway_create(p_order_ref TEXT, p_lease_seconds INTEGER DEFAULT 30) RETURNS BOOLEAN AS $$
DECLARE
    v_id BIGINT;
BEGIN
    UPDATE pay_orders SET gateway_create_lease_until = now() + make_interval(secs => p_lease_seconds)
     WHERE order_ref = p_order_ref AND gateway_order_id IS NULL AND status = 'created'
       AND (gateway_create_lease_until IS NULL OR gateway_create_lease_until < now())
    RETURNING id INTO v_id;
    RETURN v_id IS NOT NULL;
END;
$$ LANGUAGE plpgsql;
