-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _pay_refund_queue_resolve
--
-- Closes a refund-queue entry after a human dealt with it. Actor and note are mandatory (the audit trail); a closed
-- entry cannot be reopened or re-closed with a different status.
CREATE OR REPLACE FUNCTION _pay_refund_queue_resolve(p_id BIGINT, p_status TEXT, p_actor TEXT, p_note TEXT) RETURNS TEXT AS $$
DECLARE
    v_row pay_refund_queue;
BEGIN
    IF p_status NOT IN ('refunded', 'applied_manually', 'dismissed') THEN
        RAISE EXCEPTION '_pay_refund_queue_resolve: status must be refunded, applied_manually or dismissed (got "%").', p_status USING ERRCODE = 'PY020';
    END IF;
    IF p_actor IS NULL OR btrim(p_actor) = '' OR p_note IS NULL OR btrim(p_note) = '' THEN
        RAISE EXCEPTION '_pay_refund_queue_resolve: actor and note are required.' USING ERRCODE = 'PY020';
    END IF;
    SELECT * INTO v_row FROM pay_refund_queue WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'refund-queue entry % does not exist.', p_id USING ERRCODE = 'PY020';
    END IF;
    IF v_row.status <> 'open' THEN
        RAISE EXCEPTION 'refund-queue entry % is already %.', p_id, v_row.status USING ERRCODE = 'PY021';
    END IF;
    UPDATE pay_refund_queue SET status = p_status, resolved_at = now(), resolved_by = p_actor, resolution_note = p_note WHERE id = p_id;
    RETURN p_status;
END;
$$ LANGUAGE plpgsql;
