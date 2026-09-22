-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: tables :: inv_gst_state_codes — split from Gst/025_gst_state_codes.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: CBIC GST state/UT codes — PORT of `Support/GstStateCodes.php`
--
-- The state-code table is DATA, not code (the "every VALUE is DATA" principle).
-- Two tables: the canonical code->name set, and the accepted name aliases
-- (lowercase, incl. common spelling/punctuation variants) -> code. Functions carry
-- only the lookup FORMULA. `resolve()` returns NULL (never a guess) for an
-- unassigned 2-digit code ('00','28','92','99') or an unrecognised name.

CREATE TABLE inv_gst_state_codes (
    code            TEXT PRIMARY KEY,   -- 2-digit CBIC code
    canonical_name  TEXT NOT NULL       -- display name for the resolved code
);
