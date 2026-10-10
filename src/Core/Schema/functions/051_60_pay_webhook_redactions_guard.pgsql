-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: pay_webhook_redactions_guard (append-only audit)
CREATE OR REPLACE FUNCTION pay_webhook_redactions_guard() RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'pay_webhook_redactions is append-only.' USING ERRCODE = 'PY022';
END;
$$ LANGUAGE plpgsql;
