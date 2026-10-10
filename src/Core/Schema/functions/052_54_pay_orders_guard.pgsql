-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: pay_orders_guard
--
-- Orders and events are financial records: an order is never deleted and what was asked for
-- (tenant, purpose, amount, currency, gateway, mode, spec, key) never changes; only its
-- lifecycle columns move, and only forward (created -> open -> paid | cancelled, a paid order
-- never changes). Events are append-only.
CREATE OR REPLACE FUNCTION pay_orders_guard() RETURNS TRIGGER AS $$
BEGIN
    IF TG_TABLE_NAME = 'pay_events' THEN
        RAISE EXCEPTION 'pay_events is append-only.' USING ERRCODE = 'PY022';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'order % cannot be deleted: it is a financial record.', OLD.order_ref USING ERRCODE = 'PY022';
    END IF;
    IF NEW.order_ref IS DISTINCT FROM OLD.order_ref OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
       OR NEW.platform_code IS DISTINCT FROM OLD.platform_code OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
       OR NEW.request_hash IS DISTINCT FROM OLD.request_hash OR NEW.purpose IS DISTINCT FROM OLD.purpose
       OR NEW.catalog_ref IS DISTINCT FROM OLD.catalog_ref OR NEW.amount_minor IS DISTINCT FROM OLD.amount_minor
       OR NEW.currency IS DISTINCT FROM OLD.currency OR NEW.gateway_code IS DISTINCT FROM OLD.gateway_code
       OR NEW.mode IS DISTINCT FROM OLD.mode OR NEW.series_code IS DISTINCT FROM OLD.series_code
       OR NEW.invoice_spec IS DISTINCT FROM OLD.invoice_spec THEN
        RAISE EXCEPTION 'order %: the request it records is immutable.', OLD.order_ref USING ERRCODE = 'PY022';
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
           (OLD.status = 'created' AND NEW.status IN ('open', 'paid', 'cancelled'))
        OR (OLD.status = 'open' AND NEW.status IN ('paid', 'cancelled'))) THEN
        RAISE EXCEPTION 'order %: status % -> % is not allowed (orders only move forward; a cancelled or paid order never reopens).',
            OLD.order_ref, OLD.status, NEW.status USING ERRCODE = 'PY022';
    END IF;
    IF OLD.invoice_id IS NOT NULL AND NEW.invoice_id IS DISTINCT FROM OLD.invoice_id THEN
        RAISE EXCEPTION 'order %: its invoice never changes once set.', OLD.order_ref USING ERRCODE = 'PY022';
    END IF;
    IF OLD.status = 'paid' AND (NEW.status <> 'paid' OR NEW.gateway_order_id IS DISTINCT FROM OLD.gateway_order_id
                                OR NEW.invoice_id IS DISTINCT FROM OLD.invoice_id OR NEW.payment_id IS DISTINCT FROM OLD.payment_id
                                OR NEW.captured_payment_id IS DISTINCT FROM OLD.captured_payment_id) THEN
        RAISE EXCEPTION 'order % is paid and final.', OLD.order_ref USING ERRCODE = 'PY022';
    END IF;
    IF OLD.gateway_order_id IS NOT NULL AND NEW.gateway_order_id IS DISTINCT FROM OLD.gateway_order_id THEN
        RAISE EXCEPTION 'order %: the gateway order id never changes once attached.', OLD.order_ref USING ERRCODE = 'PY022';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
