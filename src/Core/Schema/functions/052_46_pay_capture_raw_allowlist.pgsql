-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _pay_capture_raw_allowlist (INTERNAL)
--
-- Server-side privacy filter for pay_captured_payments.raw_payload, which is an accounting record that outlives the inbox's
-- raw body. Whatever a caller passes, ONLY allow-listed keys with values of the expected FORMAT survive; everything else is
-- dropped, so a direct caller cannot store arbitrary JSON (payer e-mail, phone, card or UPI details...).
--
--   accepts   {"fields": {...}, "body_sha256": "<64 hex>"}  (what the PHP module sends)  or a flat gateway payment object
--   keeps     id, order_id, amount (number, or {value, currency_code}), currency, status, method, captured, amount_refunded,
--             created_at, captured_at, custom_id, create_time, update_time, and notes.{order_id, platform_code, tenant_id,
--             invoice_ref} - each only if it matches its strict format (ids, ISO currency, uuid, our order reference, a
--             platform code); a value that does not match is dropped, not repaired
--   adds      received_sha256 = SHA-256 of exactly what was passed in, as proof of what the caller sent
--   returns   {"fields": {...}, "body_sha256": ..., "received_sha256": ...}, or NULL for NULL / unparseable input
CREATE OR REPLACE FUNCTION _pay_capture_raw_allowlist(p_raw TEXT) RETURNS JSONB AS $$
DECLARE
    v_in     JSONB;
    v_src    JSONB;
    v_out    JSONB := '{}'::jsonb;
    v_notes  JSONB := '{}'::jsonb;
    v_key    TEXT;
    v_val    JSONB;
    v_hash   TEXT;
    v_txt    TEXT;
BEGIN
    IF p_raw IS NULL THEN
        RETURN NULL;
    END IF;
    BEGIN
        v_in := p_raw::jsonb;
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END;
    IF jsonb_typeof(v_in) <> 'object' THEN
        RETURN NULL;
    END IF;
    v_src := CASE WHEN jsonb_typeof(v_in -> 'fields') = 'object' THEN v_in -> 'fields' ELSE v_in END;

    FOR v_key, v_val IN SELECT * FROM jsonb_each(v_src) LOOP
        v_txt := CASE WHEN jsonb_typeof(v_val) = 'string' THEN v_val #>> '{}' ELSE NULL END;
        IF v_key IN ('id', 'order_id') AND v_txt ~ '^[A-Za-z0-9_-]{1,100}$' THEN
            v_out := v_out || jsonb_build_object(v_key, v_val);
        ELSIF v_key = 'currency' AND v_txt ~ '^[A-Z]{3}$' THEN
            v_out := v_out || jsonb_build_object(v_key, v_val);
        ELSIF v_key IN ('status', 'method') AND v_txt ~ '^[A-Za-z_]{1,32}$' THEN
            v_out := v_out || jsonb_build_object(v_key, v_val);
        ELSIF v_key = 'captured' AND jsonb_typeof(v_val) = 'boolean' THEN
            v_out := v_out || jsonb_build_object(v_key, v_val);
        ELSIF v_key IN ('amount_refunded', 'created_at', 'captured_at') AND jsonb_typeof(v_val) = 'number' THEN
            v_out := v_out || jsonb_build_object(v_key, v_val);
        ELSIF v_key = 'amount' AND jsonb_typeof(v_val) = 'number' THEN
            v_out := v_out || jsonb_build_object(v_key, v_val);
        ELSIF v_key = 'amount' AND jsonb_typeof(v_val) = 'object' THEN
            v_out := v_out || jsonb_build_object('amount', jsonb_strip_nulls(jsonb_build_object(
                'value', CASE WHEN (v_val ->> 'value') ~ '^[0-9]{1,12}(\.[0-9]{1,4})?$' THEN v_val -> 'value' END,
                'currency_code', CASE WHEN (v_val ->> 'currency_code') ~ '^[A-Z]{3}$' THEN v_val -> 'currency_code' END)));
        ELSIF v_key = 'custom_id' AND v_txt ~ '^[A-Za-z0-9_|.-]{1,127}$' THEN
            v_out := v_out || jsonb_build_object(v_key, v_val);
        ELSIF v_key IN ('create_time', 'update_time') AND v_txt ~ '^[0-9TZ:.+-]{10,40}$' THEN
            v_out := v_out || jsonb_build_object(v_key, v_val);
        ELSIF v_key = 'notes' AND jsonb_typeof(v_val) = 'object' THEN
            IF (v_val ->> 'order_id') ~ '^ord_[0-9a-f]{32}$' THEN v_notes := v_notes || jsonb_build_object('order_id', v_val -> 'order_id'); END IF;
            IF (v_val ->> 'invoice_ref') ~ '^ord_[0-9a-f]{32}$' THEN v_notes := v_notes || jsonb_build_object('invoice_ref', v_val -> 'invoice_ref'); END IF;
            IF (v_val ->> 'platform_code') ~ '^[A-Za-z0-9_.-]{1,50}$' THEN v_notes := v_notes || jsonb_build_object('platform_code', v_val -> 'platform_code'); END IF;
            IF (v_val ->> 'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN v_notes := v_notes || jsonb_build_object('tenant_id', v_val -> 'tenant_id'); END IF;
        END IF;
        -- anything else (email, contact, card, vpa, description, address, ...) is silently dropped
    END LOOP;
    IF v_notes <> '{}'::jsonb THEN
        v_out := v_out || jsonb_build_object('notes', v_notes);
    END IF;

    v_hash := v_in ->> 'body_sha256';
    RETURN jsonb_strip_nulls(jsonb_build_object(
        'fields', v_out,
        'body_sha256', CASE WHEN v_hash ~ '^[0-9a-f]{64}$' THEN v_hash END,
        'received_sha256', encode(sha256(convert_to(p_raw, 'UTF8')), 'hex')));
END;
$$ LANGUAGE plpgsql IMMUTABLE;
