-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _pay_queue_refund (INTERNAL)
--
-- Writes the refund-queue entry for money that arrived and could not be applied. Idempotent per (gateway, transaction): a
-- redelivery adds nothing. Real money must never live only in the webhook inbox, which is a retention-limited log.
CREATE OR REPLACE FUNCTION _pay_queue_refund(
    p_gateway_code TEXT, p_txn TEXT, p_order_ref TEXT, p_tenant UUID, p_platform VARCHAR(50),
    p_amount BIGINT, p_currency TEXT, p_reason TEXT, p_detail TEXT
) RETURNS VOID AS $$
    INSERT INTO pay_refund_queue (gateway_code, gateway_txn_ref, order_ref, tenant_id, platform_code, amount_minor, currency, reason, detail)
    VALUES (p_gateway_code, p_txn, p_order_ref, p_tenant, p_platform, coalesce(p_amount, 0), coalesce(p_currency, '???'), p_reason, p_detail)
    ON CONFLICT (gateway_code, gateway_txn_ref) DO NOTHING;
$$ LANGUAGE sql;
