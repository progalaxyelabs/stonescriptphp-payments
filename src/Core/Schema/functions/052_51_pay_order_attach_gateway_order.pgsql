-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: pay_order_attach_gateway_order
--
-- Records the gateway's order id on a created order and opens it. FIRST WINS: if two
-- concurrent identical requests each created a gateway order, only the first attach sticks and
-- both callers get the winning id back (the loser's gateway order simply stays unpaid), so a
-- retried or double-clicked request always ends up with the same order.
CREATE OR REPLACE FUNCTION pay_order_attach_gateway_order(p_order_ref TEXT, p_gateway_order_id TEXT)
RETURNS TABLE (o_gateway_order_id TEXT, o_attached BOOLEAN, o_status TEXT) AS $$
DECLARE
    v_row pay_orders;
BEGIN
    IF p_gateway_order_id IS NULL OR btrim(p_gateway_order_id) = '' THEN
        RAISE EXCEPTION 'pay_order_attach_gateway_order: gateway_order_id is required.' USING ERRCODE = 'PY030';
    END IF;
    UPDATE pay_orders SET gateway_order_id = p_gateway_order_id, status = 'open', gateway_create_lease_until = NULL
     WHERE order_ref = p_order_ref AND gateway_order_id IS NULL AND status = 'created'
    RETURNING * INTO v_row;
    IF FOUND THEN
        o_gateway_order_id := v_row.gateway_order_id; o_attached := TRUE; o_status := v_row.status;
        RETURN NEXT;
        RETURN;
    END IF;
    SELECT * INTO v_row FROM pay_orders WHERE order_ref = p_order_ref;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'order "%" does not exist.', p_order_ref USING ERRCODE = 'PY030';
    END IF;
    o_gateway_order_id := v_row.gateway_order_id; o_attached := FALSE; o_status := v_row.status;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
