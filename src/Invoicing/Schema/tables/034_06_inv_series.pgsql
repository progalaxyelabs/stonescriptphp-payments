-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: tables :: inv_series
--
-- A numbering series: the unit of "consecutive serial number" in CGST Rules
-- 2017, Rule 46(b): at most 16 characters, letters / numerals / hyphen / slash,
-- unique for a financial year, in one or several series.
--
--   number = prefix || sep || [ fy_label || sep ] || lpad(seq, width, '0')
--   e.g.     AB/26-27/00001   (fy_reset)      AB/00001   (continuous)
--
--   kind      invoice | credit_note | receipt   (each kind has its OWN consecutive serial)
--   mode      live | test.  A TEST series is structurally separate from a live one:
--             its prefix MUST start with TEST and a live prefix MUST NOT, the
--             allocator refuses to cross modes, and inv_invoices re-checks it.
--   fy_reset  true  -> one counter per Indian financial year (April-March, IST) and
--                      the FY label is part of the number;
--             false -> one counter for ever.
--
-- width bounds the longest possible number: _inv_series_create() rejects a series
-- whose longest number could exceed the configured maximum length (16) or leave the
-- allowed charset, at CREATION time rather than at the 100,000th invoice. A series
-- that runs out of serials refuses to issue; it never produces a longer number.
--
-- The identity columns (prefix, sep, width, fy_reset, mode, kind, issuer, code) are
-- immutable (trigger); only is_active may change. Create a new series instead.
-- The "head" of a series (prefix || sep) must not be a prefix of any other series'
-- head (enforced by _inv_series_create), so two series can never mint the same string.
CREATE TABLE inv_series (
    id          BIGSERIAL PRIMARY KEY,
    series_code TEXT NOT NULL UNIQUE CHECK (series_code ~ '^[a-z0-9][a-z0-9_-]{0,48}$'),
    issuer_id   BIGINT NOT NULL REFERENCES inv_issuers(id),
    kind        TEXT NOT NULL CHECK (kind IN ('invoice', 'credit_note', 'receipt')),
    mode        TEXT NOT NULL CHECK (mode IN ('live', 'test')),
    prefix      TEXT NOT NULL CHECK (prefix <> ''),
    sep         TEXT NOT NULL DEFAULT '/',
    width       INTEGER NOT NULL CHECK (width BETWEEN 1 AND 12),
    fy_reset    BOOLEAN NOT NULL,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  TEXT NOT NULL,
    -- TEST and live can never share a prefix space: test prefixes start with TEST, live ones never do.
    CONSTRAINT inv_series_mode_prefix CHECK (
        (mode = 'test' AND upper(prefix) LIKE 'TEST%')
        OR (mode = 'live' AND upper(prefix) NOT LIKE 'TEST%'))
);
CREATE INDEX inv_series_issuer ON inv_series (issuer_id);
