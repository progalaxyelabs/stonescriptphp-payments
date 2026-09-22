# Canonical load order — stonescriptphp-pay (SQL billing side)

This is the **dependency-ordered set of PostgreSQL migration files** for the
billing/invoicing/tax side of the merged `stonescriptphp-pay` package (the
`Capture/`, `Pricing/`, `Metering/`, `Tax/India/`, `Invoicing/`, `Outbox/`
directories under `src/`), not a two-bucket (tables-then-functions) scan.
Functions depend on earlier functions and on data rows; one file (`031`) is a
*fix* that redefines a `003` function and must run **after** the tax engine
(`030`) but **before** `032`. Money primitives (`024`) must precede the tax
engine (`030`); invoice tables (`034`) precede invoice functions (`035`); the
outbox trigger (`037`) depends on both. `Capture`'s prefix range (`001`) is
independent of the rest — it has no dependency on Pricing/Invoicing and can
load first or anywhere before a consumer's own domain function needs it. A
plain alphabetical tables/functions split cannot express any of this — so the
load order is **explicit and global**.

## The one rule

> Load every `*.pgsql` / `*.psql` file in **ascending order of its 3-digit
> filename prefix**, across all Features. The prefix is global (unique across
> the whole billing/invoicing side); a file's Feature directory is
> organisational only and never changes its load position.

`tests/run-suite.sh` implements exactly this (`find … | sort` by basename).

## Scope layer

All schema here is the **`main`** scope (main-DB / merchant-of-record + product
subscription-billing). A per-tenant scope layer is **deferred** (no tenant
routing is built in this module).

## BUCKET layout (all features, as of the 2026-09-22 merge)

Every feature — including `Tax/India` (the former `Gst`, see below) — uses a
**bucketed** layout: one SQL object per file, grouped by kind:

```
src/<Feature>/Schema/tables/NNN_*.pgsql      # CREATE TABLE (+ its own indexes)
src/<Feature>/Schema/functions/NNN_*.pgsql   # CREATE [OR REPLACE] FUNCTION / TRIGGER
src/<Feature>/Schema/seeders/NNN_*.pgsql     # reference-data INSERTs
src/<Feature>/Schema/types/NNN_*.pgsql       # CREATE TYPE / DOMAIN
src/<Feature>/Schema/views/NNN_*.pgsql       # CREATE [OR REPLACE] VIEW
```

**`Gst` → `Tax/India` migration is now COMPLETE.** The old linear
`src/Gst/Schema/main/NNN_*.pgsql` layout (single file per numeric group) has
been **deleted** — it was byte-identical content to the bucketed
`src/Tax/India/Schema/{tables,functions,seeders,types}/` files it was split
into (verified: same `CREATE TABLE`/`CREATE FUNCTION` bodies, same 24
functions, same 5 tables, only the file boundaries changed), so there is
nothing left to reconcile and no risk of the "run both, get duplicate CREATE
TABLE" failure a half-finished migration would otherwise leave in
`tests/run-suite.sh` (which globs `src/**/*.pgsql` unconditionally — it would
have loaded both the old and new copies of every Gst/Tax/India object on a
fresh DB before this cleanup).

**A third, independent bug found and fixed in the same cleanup (2026-09-22):**
the bucket split of `003_pricing_functions.pgsql` DROPPED
`get_customer_credit_balance`'s original definition entirely — only `031`'s
later `CREATE OR REPLACE` "fix" survived the split, and `031` sorts AFTER the
whole Tax/India group (024-030, 032) in load order. Any test at a prefix
between `003` and `031` (e.g. `tests/sql/014_test_credit_balance.psql`) found
NO such function on a fresh DB. Restored as
`src/Pricing/Schema/functions/003_12_get_customer_credit_balance.pgsql`,
verbatim from the last committed monolithic source
(`stonescriptphp-invoice` git `fe5c7f2`), preserving `031`'s own reason to
exist (it still `CREATE OR REPLACE`s this with the purchase-time-guard fix
later) — only the identity columns were updated to match the rest of this
merge.

**A second, independent basename-collision bug found and fixed in the same
cleanup (2026-09-22):** the `025`/`026`/`032` groups' bucket split gave the
`tables/` and `seeders/` file for the SAME object the IDENTICAL basename
(e.g. both `tables/025_01_inv_gst_state_codes.pgsql` and
`seeders/025_01_inv_gst_state_codes.pgsql`) — unlike Outbox's `037` group,
which was correctly given the `_1x` (tables) / `_3x` (seeders) / `_5x`
(functions) sub-block split this file's own "BUCKET layout" section
documents. Since `find | sort` orders purely by basename, two files sharing
one basename sort in filesystem-traversal order, NOT guaranteed
table-before-seeder — this reproduced, on a fresh DB, as the exact
"`INSERT`s into a table that doesn't exist yet" failure class the merge
brief called out. Fixed by applying the SAME `_1x`/`_3x` convention Outbox
already uses: `tables/025_01_*` -> `tables/025_11_*`,
`seeders/025_01_*` -> `seeders/025_31_*` (and likewise for `025_02`, `026_01`,
`026_02`, `032_01`). No content changed, only the five affected pairs'
filenames — deterministic table-before-seed ordering is now structurally
guaranteed the same way it already was for every other feature.

**The global numeric prefix is still the ONE load-order rule** — bucketing
only reorganises files WITHIN a feature's existing prefix range, it never
changes which prefix range a feature owns. Within one prefix group, files are
further sub-ordered by a second two-digit block so that
`tables < seeders < functions` always sorts correctly by plain basename, since
`tests/run-suite.sh` and the gateway both load in ascending basename order
with no notion of "bucket" — e.g. Outbox's `037` group uses `037_1x_*` for
tables, `037_3x_*` for seeders, `037_5x_*` for functions. Cross-feature
dependencies that used to live in the SAME linear file (e.g. Metering's `023`
ALTERing a Pricing table) were resolved by folding the ALTER into the owning
table's `CREATE TABLE` where the final schema is identical either way (see
`023_subscription_plus_overage` history) — never by leaving a same-prefix
table/function ordering ambiguous.

## Deployable schema — `src/**/*.pgsql` (load with `ON_ERROR_STOP=1`)

Pure DDL + framework reference-data rows. Loads standalone into an empty
database with no test/seed dependency. **These files carry NO psql
meta-commands** (`\echo`, `\gset`, …) and NO test assertions or seed rows —
the StoneScriptDB Gateway applies them via libpq `batch_execute`, which
rejects psql meta-commands, so anything non-DDL belongs in `tests/sql/`,
never here. (`031`'s purchase-time-FIFO-guard regression lived here through
`v0.4.0`; `v0.4.1` moved it to
`tests/sql/031_test_credit_balance_purchase_time_guard.psql` — the `031`
schema file is now pure DDL.)

Group order (each group's files are spread across the feature's
`tables/functions/seeders/...` bucket directories):

```
001                      Capture   (idempotent gateway-agnostic payment-capture primitive — independent of the rest)
001, 002, 003            Pricing   (plans, tenant-keyed pricing enrollments, subscription core)
017, 019, 020, 022, 023  Metering  (wallet, passthrough, credit ledger, postpaid, subscription+overage)
024-030, 032             Tax/India (formerly Gst — money primitives, state codes, config/slabs, number formatter, party, line/invoice validation, tax engine, FX statutory value)
031                      Pricing   (fix to 003's get_customer_credit_balance — must sit after 030, before 032)
033                      Tax       (country-agnostic: inv_tax_scheme + inv_resolve_tax_scheme — additive multi-country scaffolding, see the note on inv_tax_scheme; independent of 024-032/034/035, may load anywhere after money primitives exist)
034, 035                 Invoicing (persisted invoices, payments, gateway routing, status lifecycle, CRM chase)
037                      Outbox    (transactional-outbox product<->central intimation)
```

Note `Capture`'s own prefix range (`001`) is a SEPARATE numbering track from
`Pricing`'s `001` — they live in different Feature directories
(`src/Capture/Schema/` vs `src/Pricing/Schema/`) so there is no collision;
the "ascending prefix" rule is scoped within `find`'s natural per-directory
traversal plus final basename sort, which `tests/run-suite.sh` already
implements correctly (two files named `001_*.pgsql` in different
directories both sort by their full basename, not by feature).

## Full test suite — schema + tests interleaved by prefix (tests with `ON_ERROR_STOP=0`)

The `tests/sql/*.psql` files (scenario demos, seeds, the differential-golden
regression, and the by-design `ER*` negative cases) interleave with the
schema at their own prefix positions. `NNN_*_demo.psql` files are the
demo/seed halves split out of the `019/022/023` prototype files (the DDL half
stays in `src`); at an equal prefix the `src` `.pgsql` sorts before the
`tests` `.psql` companion. `tests/sql/031_test_credit_balance_purchase_time_guard.psql`
is the same pattern: the purchase-time-FIFO-guard regression (a `\echo` + a
`DO` assertion that RAISEs if the guard is absent) split out of the `031`
schema fix, sorting right after
`src/.../031_fix_credit_balance_purchase_time_guard.pgsql` at the shared
`031` prefix so it runs once the guarded function body is installed.

Golden proof: `tests/sql/033_test_differential_golden.psql` — **1036
assertions, every expected value harvested from the original PHP engine**;
it is self-contained and is what proves the SQL path equivalent after the
PHP was deleted. Do not edit it.

`tests/sql/039_test_now_defaults.psql` proves the step-2 `now()` DEFAULT
transform: callers may OMIT every `[NOW-CANDIDATE]` param/column and the
module fills `now()`.

Run everything:

```bash
PSQL='psql -h localhost -U postgres' DB=payments_suite ./tests/run-suite.sh
# deploy the schema only, into an ALREADY-PROVISIONED database (never drops
# or creates one — see the safety note at the top of tests/run-suite.sh):
PSQL='psql -h localhost -U postgres' DB=my_already_provisioned_db ./tests/run-suite.sh --schema-only
```
