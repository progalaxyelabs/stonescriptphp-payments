-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _ledger_verify (INTERNAL, read-only; the nightly job: bin/pay-wallet verify-ledger)
--
-- INTERNAL because it returns rows across ALL tenants (wallet ids, balances): it is an operator's audit, never an application call.
-- Proves the wallet books are consistent. Returns ONLY the violations: ZERO ROWS = the books are sound. Checks:
--   unbalanced_txn    a posting whose entries do not sum to zero
--   wallet_balance    the ledger balance of wallet:<id> differs from the sum of that wallet's grants' remaining credit
--   grant_parts       a grant where granted != remaining + forfeited + what drains took from it
--   drain_parts       a drain whose allocations do not add up to what it debited
--   forfeit_parts     a grant's forfeited credit differs from its forfeit record
-- p_wallet_id limits the per-wallet checks to one wallet (the posting-balance check always covers everything).
CREATE OR REPLACE FUNCTION _ledger_verify(p_wallet_id BIGINT DEFAULT NULL)
RETURNS TABLE (o_check TEXT, o_subject TEXT, o_expected BIGINT, o_actual BIGINT) AS $$
BEGIN
    RETURN QUERY
    SELECT 'unbalanced_txn', 'txn:' || t.id, 0::bigint, sum(e.amount_milli)::bigint
      FROM ledger_txns t JOIN ledger_entries e ON e.txn_id = t.id GROUP BY t.id HAVING sum(e.amount_milli) <> 0;
    RETURN QUERY
    SELECT 'unbalanced_txn', 'txn:' || t.id, 0::bigint, 0::bigint FROM ledger_txns t WHERE NOT EXISTS (SELECT 1 FROM ledger_entries e WHERE e.txn_id = t.id);
    RETURN QUERY
    SELECT 'wallet_balance', 'wallet:' || w.id,
           coalesce((SELECT sum(g.remaining_milli) FROM wlt_grants g WHERE g.wallet_id = w.id), 0)::bigint,
           coalesce((SELECT sum(e.amount_milli) FROM ledger_entries e WHERE e.account = 'wallet:' || w.id), 0)::bigint
      FROM wlt_wallets w
     WHERE (p_wallet_id IS NULL OR w.id = p_wallet_id)
       AND coalesce((SELECT sum(g.remaining_milli) FROM wlt_grants g WHERE g.wallet_id = w.id), 0)
           <> coalesce((SELECT sum(e.amount_milli) FROM ledger_entries e WHERE e.account = 'wallet:' || w.id), 0);
    RETURN QUERY
    SELECT 'grant_parts', 'grant:' || g.id, g.granted_milli,
           (g.remaining_milli + g.forfeited_milli + coalesce((SELECT sum(a.milli) FROM wlt_drain_allocations a WHERE a.grant_id = g.id), 0))::bigint
      FROM wlt_grants g
     WHERE (p_wallet_id IS NULL OR g.wallet_id = p_wallet_id)
       AND g.granted_milli <> g.remaining_milli + g.forfeited_milli + coalesce((SELECT sum(a.milli) FROM wlt_drain_allocations a WHERE a.grant_id = g.id), 0);
    RETURN QUERY
    SELECT 'drain_parts', 'drain:' || d.id, d.debited_milli, coalesce((SELECT sum(a.milli) FROM wlt_drain_allocations a WHERE a.drain_id = d.id), 0)::bigint
      FROM wlt_drains d
     WHERE (p_wallet_id IS NULL OR d.wallet_id = p_wallet_id)
       AND d.debited_milli <> coalesce((SELECT sum(a.milli) FROM wlt_drain_allocations a WHERE a.drain_id = d.id), 0);
    RETURN QUERY
    SELECT 'forfeit_parts', 'grant:' || g.id, g.forfeited_milli, coalesce((SELECT sum(f.milli) FROM wlt_forfeits f WHERE f.grant_id = g.id), 0)::bigint
      FROM wlt_grants g
     WHERE (p_wallet_id IS NULL OR g.wallet_id = p_wallet_id)
       AND g.forfeited_milli <> coalesce((SELECT sum(f.milli) FROM wlt_forfeits f WHERE f.grant_id = g.id), 0);
END;
$$ LANGUAGE plpgsql STABLE;
