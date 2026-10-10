-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _ent_overdue / _ent_overdue_cutoff (INTERNAL)
-- _ent_overdue: the due date of the OLDEST unpaid invoice billed to a postpaid entitlement (NULL = nothing owed).
-- _ent_overdue_cutoff: when that entitlement becomes read-only (that due date + ent_read_only_after_days), NULL when nothing is owed.
CREATE OR REPLACE FUNCTION _ent_overdue(p_entitlement_id BIGINT) RETURNS TIMESTAMPTZ AS $$
    SELECT min(coalesce(i.due_date, i.issued_at))
      FROM ent_billing_runs r JOIN inv_invoices i ON i.id = r.invoice_id
     WHERE r.entitlement_id = p_entitlement_id AND i.status IN ('issued', 'due');
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION _ent_overdue_cutoff(p_entitlement_id BIGINT) RETURNS TIMESTAMPTZ AS $$
    SELECT _ent_overdue(p_entitlement_id) + make_interval(days => _pay_config_int('ent_read_only_after_days')::int);
$$ LANGUAGE sql STABLE;
