-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: tables :: ledger_txns, ledger_entries (double-entry wallet ledger)
--
-- Append-only. A posting is a ledger_txn with two or more ledger_entries whose amounts SUM TO ZERO (enforced by a deferred constraint
-- trigger, so an unbalanced posting cannot commit). Accounts are text:
--   wallet:<wallet_id>   the liability to the customer; its balance (the sum of its entries) = the wallet's milli-credits held
--   src:topup | src:free_grant | src:opening      where credit came from (negative: it left the source)
--   sink:consumption | sink:forfeiture | sink:refund | sink:clawback   where credit went (positive)
-- Posting kinds: topup, free_grant, opening, drain, forfeit, and (reserved for credit notes and refunds, L7.6) refund, reversal, clawback.
-- wallet balance = sum of the wallet account; _ledger_verify() proves it equals the grants' remaining credit, every posting balances,
-- and every grant satisfies granted = remaining + forfeited + drained.
CREATE TABLE ledger_txns (
    id         BIGSERIAL PRIMARY KEY,
    kind       TEXT NOT NULL CHECK (kind IN ('topup', 'free_grant', 'opening', 'drain', 'forfeit', 'refund', 'reversal', 'clawback')),
    ref        TEXT NOT NULL,
    at         TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE ledger_entries (
    id          BIGSERIAL PRIMARY KEY,
    txn_id      BIGINT NOT NULL REFERENCES ledger_txns(id),
    account     TEXT NOT NULL CHECK (btrim(account) <> ''),
    amount_milli BIGINT NOT NULL CHECK (amount_milli <> 0)
);
CREATE INDEX ledger_entries_txn ON ledger_entries (txn_id);
CREATE INDEX ledger_entries_account ON ledger_entries (account);
