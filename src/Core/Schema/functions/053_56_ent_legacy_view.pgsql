-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: ent_legacy_subscriptions (compatibility view)
--
-- The framework's legacy `subscriptions` table, as a read-only projection of ent_entitlements, for consumers that have not cut over yet.
-- MIGRATION STORY (a platform with the legacy table):
--   1. _ent_import_legacy('subscriptions', 'migration') copies every row into ent_entitlements (idempotent, audited, nothing changes
--      for users: access already follows ent_get from here on);
--   2. THE GATE: _ent_cutover_check('subscriptions', '<platform>', '<legacy missing mode>') must PASS - it raises unless _ent_verify_legacy
--      reports ZERO differences, no legacy row is invalid, and the platform's missing-subscription mode matches the legacy one. Run it (after the final
--      delta import: _ent_import_legacy(..., p_sync => true)) in the SAME window in which every legacy writer has been stopped; and
--   3. rename the legacy table to an archive (statutory retention: never dropped by this package) and
--      CREATE VIEW subscriptions AS SELECT * FROM ent_legacy_subscriptions;  - old readers keep working, there is ONE store.
-- The view's `expires_at` is the moment access ends: the period end, or for a postpaid entitlement the moment it turns read-only.
CREATE OR REPLACE VIEW ent_legacy_subscriptions AS
SELECT e.id::integer                                                          AS id,
       e.platform_code,
       e.tenant_id::text                                                      AS tenant_id,
       NULL::varchar(255)                                                     AS owner_email,
       left(coalesce(e.plan_ref, 'trial'), 50)::varchar(50)                   AS plan_code,
       (CASE WHEN e.status = 'trial' OR (e.source = 'trial' AND e.status IN ('read_only', 'past_due')) THEN 'trial'
             WHEN e.status = 'suspended' THEN 'suspended'
             WHEN e.status = 'ended' THEN 'cancelled'
             ELSE 'active' END)::varchar(50)                                  AS status,
       e.started_at,
       (CASE WHEN e.status = 'ended' THEN least(coalesce(e.current_period_end, e.updated_at), e.updated_at)
             WHEN e.billing_mode = 'postpaid' THEN coalesce(_ent_overdue_cutoff(e.id), 'infinity'::timestamptz)
             ELSE coalesce(e.current_period_end, 'infinity'::timestamptz) END) AS expires_at,
       (CASE WHEN e.status = 'ended' THEN e.updated_at END)                   AS cancelled_at,
       e.created_at,
       e.updated_at
  FROM ent_entitlements e
 WHERE e.product = 'default';
