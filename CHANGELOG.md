# Changelog

All notable changes to `progalaxyelabs/stonescriptphp-payments` — the unified
payment system that supersedes and `replace`s the previously separate
`progalaxyelabs/stonescriptphp-pay` (gateway-transport drivers) and
`progalaxyelabs/stonescriptphp-invoice` (SQL-first billing/invoicing) — are
documented here.

## v0.1.0

**Structural merge:** `stonescriptphp-pay` (Razorpay/PayPal gateway transport
drivers, the `pay_captured_payments`/`pay_record_captured_payment` idempotent
capture primitive) and `stonescriptphp-invoice` (this package's SQL-first
Pricing/Metering/Tax/Invoicing/Outbox) are now ONE repo/package/version —
owner-directed 2026-09-22. See `README.md` for the merged architecture.
Completed the in-flight `Gst` -> `Tax/India` bucket-layout migration (deleted
the superseded linear `src/Gst/Schema/main/`) and fixed two load-order bugs
the half-finished split had left behind — see `LOAD-ORDER.md`.

**Identity alignment to `progalaxyelabs-auth` (breaking schema change):**
every identity-bearing table/function now takes `tenant_id UUID` +
`platform_code VARCHAR(50)` — matching `progalaxyelabs-auth`'s own
`tenant_memberships` shape exactly, resolved from the caller's JWT, never a
cross-DB FK. The prototype `customers` fixture table (`customers.id
BIGSERIAL`) is deleted entirely; no `customer_id` column survives anywhere
in this package. Every SQL function that took `p_customer_id BIGINT` now
takes `p_tenant_id UUID, p_platform_code VARCHAR(50)` instead — a breaking
signature change for any caller (there are none yet in the ecosystem; this
package was pre-adoption).

**Multi-country tax scaffold (additive, unwired):** `inv_tax_scheme` +
`inv_resolve_tax_scheme()` resolve a tax regime by JOIN on
`billing_country_code`, mirroring `inv_resolve_gateway`'s own pattern —
country-keyed selection is data + JOIN + `CASE`, never a dynamically
dispatched function name. Seeded with India (`'in_gst'`) only;
`inv_compute_invoice` remains the sole, unchanged engine.

## v0.5.1

Packaging hygiene, no code change: the library resolves all dependencies from
Packagist — it commits no local `repositories` path overrides. A public package
must never pin a dependency to a filesystem path. `progalaxyelabs/stonescriptphp`
remains a `require-dev` + `suggest` dependency (invoice → framework, the correct
direction); local cross-package development against an unpublished framework
version uses an uncommitted `composer global config repositories.<name> path
<path>` override instead.

## v0.5.0

Adds this package's first and, by design, only PHP file:
`src/Php/InvoiceSourceAdapter.php` — a thin transport shim implementing
`StoneScriptPHP\Billing\Contracts\InvoiceSource` (published by
`progalaxyelabs/stonescriptphp` v9.17.0's `Billing\` seam) by calling
`inv_invoice_payability`/`inv_record_payment` via `Database::fn()`. Pure
marshalling — paise ints and status strings pass through unmodified; no
amount/tax/routing/idempotency logic was added to PHP (all of that remains
exclusively in the `inv_*` SQL functions, unchanged by this release).

- New: `StoneScriptPHP\Invoice\Php\InvoiceSourceAdapter` (PSR-4: `src/Php/`).
- `composer.json`: added `progalaxyelabs/stonescriptphp` as `require-dev` (adapter
  tests) + `suggest` (runtime, ONLY if you instantiate the adapter — pure-SQL
  usage of this package still needs nothing but PHP). No change to the package's
  `require` (still PHP-only) — SQL-only consumers are completely unaffected.
- New `tests/php/` PHPUnit suite (marshalling-level, via `Database::fake()`) —
  separate from the existing `tests/sql/` differential-golden suite.
- Known, documented limitation: `InvoiceSourceAdapter::recordVerifiedPayment()`
  infers `RecordPaymentResult::$alreadyRecorded` by observing the invoice's
  payability before/after the call. This technique cannot distinguish a replay
  from a fresh record for `'failed'`-status payments (which never transition the
  invoice either way), so `alreadyRecorded` is always reported `false` for
  `'failed'`. This does not affect what gets PERSISTED — the SQL function's own
  `gateway_code`+`gateway_txn_ref` uniqueness still prevents any duplicate row —
  only the adapter's after-the-fact reporting for that one status value.

## v0.4.x and earlier

Earlier `0.1.0`–`0.4.1` releases are recorded as git tags. They established the
SQL-first core, deployed entirely as PostgreSQL tables and functions:

- **Pricing** — subscription / one-time / credit plans, customers, trial controls,
  price-change pinning, renewals, and plan switching.
- **Metering** — prepaid credit wallet, monetary credit/refund ledger,
  cost-plus passthrough, postpaid arrears billing, and subscription-plus-overage.
- **GST** — the included India-GST-compatible regional tax pack: integer-paisa
  money primitives, state/region codes, config/rate slabs, configurable
  invoice-number formatting (length + charset), party/line/invoice validation, the
  origin/destination-based tax engine (intra- vs inter-region CGST/SGST-vs-IGST
  split, with tax-invoice vs no-tax document modes), and dated-FX reference INR
  value for foreign-currency invoices.
- **Invoicing** — persisted invoices and payments, data-driven gateway routing,
  the guarded status lifecycle, idempotent single-success payment recording, and
  the collections/dunning projection.
- **Outbox** — durable transactional-outbox intimation between a product database
  and a central merchant-of-record, with at-least-once delivery and idempotent
  apply (effectively exactly-once) in both directions.

A differential golden suite (`tests/sql/033_test_differential_golden.psql`) pins
every computed value against a reference implementation fed identical inputs.
