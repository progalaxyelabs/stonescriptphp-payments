-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: pay_order_get
--
-- Reads an order for status polling. Tenant-scoped: an order of another tenant or platform is
-- returned as NO ROW (not an error), so a caller cannot probe for orders it does not own.
-- The webhook is the authority that an order is paid; the client return path is a hint and
-- polls this.
CREATE OR REPLACE FUNCTION pay_order_get(p_order_ref TEXT, p_tenant_id UUID, p_platform_code VARCHAR(50))
RETURNS TABLE (
    o_order_ref TEXT, o_status TEXT, o_purpose TEXT, o_amount_minor BIGINT, o_currency TEXT, o_mode TEXT,
    o_gateway_code TEXT, o_gateway_order_id TEXT, o_invoice_id BIGINT, o_paid_at TIMESTAMPTZ
) AS $$
    SELECT o.order_ref, o.status, o.purpose, o.amount_minor, o.currency, o.mode, o.gateway_code, o.gateway_order_id, o.invoice_id, o.paid_at
      FROM pay_orders o
     WHERE o.order_ref = p_order_ref AND o.tenant_id = p_tenant_id AND o.platform_code = p_platform_code;
$$ LANGUAGE sql STABLE;
