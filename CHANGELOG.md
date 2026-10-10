# Changelog

All notable changes to `progalaxyelabs/stonescriptphp-payments` — the unified
payment system that supersedes and `replace`s the previously separate
`progalaxyelabs/stonescriptphp-pay` (gateway-transport drivers) and
`progalaxyelabs/stonescriptphp-invoice` (SQL-first billing/invoicing) — are
documented here.

## [0.2.0]

The payments convergence release: lawful gapless numbering, a durable webhook inbox, one exactly-once capture path, one entitlement store, wallet v2 with a
double-entry ledger. **Read "Breaking changes" and "Migration" before upgrading.** Items marked **CA/LEGAL TO CONFIRM** encode a policy or a tax position that
a chartered accountant or counsel must confirm before it is relied on in production.

### Breaking changes

- **`PaymentProvider` contract additions.** Implementers must add `mode()`, `publishableKeyId()`, `fetchPayment(): PaymentDetails`, `findOrderByReceipt()` and
  `webhookSignatureHeader()`; PayPal-style providers implement `ServerSideCapture`. `WebhookEvent` gains `eventId` and `orderRef`. Both bundled drivers are updated.
- **Internal functions are underscore-named and not reachable over the gateway's `/call`.** Setup, migration, scheduler and operator functions were renamed
  (`_pay_ensure_reference_data`, `_pay_apply_schema_upgrades`, `_inv_series_create`, `_inv_series_allocate`, `_inv_series_adopt`, `_inv_issuer_upsert`, `_pay_order_quote`, ...).
  **Operator actions are CLI-only**, run on the server with the platform's direct database credentials, `--actor` required and logged:
  `bin/pay-refund-queue-resolve`, `bin/pay-webhook-requeue`, `bin/pay-purge-webhooks`, `bin/pay-refund-queue-alerts`, `bin/pay-entitlement`, `bin/pay-wallet`.
  Update every migration that called an old name. The README lists the public, privileged and internal functions.
- **The library's HTTP routes live under ONE prefix, `/pay`** (`RoutePaths`: `/pay/orders`, `/pay/payments`, `/pay/quote`, `/pay/webhook/{gateway}`). Only that prefix is on
  the entitlement middleware's default write allow-list, and it follows a configured prefix.
- **v1 wallet functions are disabled per migrated platform.** `topup_wallet`, `grant_free_credits` and `record_wallet_drain` are deprecated and raise (`PY074`) once
  `_wlt_mark_platform_migrated(platform)` is run. `pay_apply_capture` no longer feeds them: wallet top-ups are wallet v2 grants bound to the capture, in milli-credits, from
  explicit-credit packs (`wlt_packs`).
- **The explicit-number path needs a mode.** `inv_issue_invoice` with an explicit invoice number requires `p_mode` (`live` or `test`); a mode is never assumed. Series-issued invoices
  take `p_series_code` and `p_mode`.
- **Framework baseline: StoneScriptPHP >= 12.0.** The framework adapters (`EntitlementMiddleware`, `FrameworkMainDbScope`, `DatabaseFnCaller`, `PostWebhookRoute`, `InvoiceSourceAdapter`) are written for and tested against 12.0.0
  (`require-dev: ^12.0`). `DatabaseFnCaller` can route named functions through the 12.0 `Database::mutate()` write boundary (opt-in).
- **Other behaviour changes:** the document date of a live invoice must be today (IST) unless `issue_date_window_days_live` is widened; a capture that disagrees with its order is queued
  for refund (`refund_required`) instead of raising; `pay_apply_capture` gained a trailing `p_issued_at`; GST engine: CGST = half of a line's rounded total tax and SGST the
  remainder (56 golden cases recorded as accepted divergences; **CA/LEGAL TO CONFIRM**).

### Migration

1. **Schema upgrade and reference data.** In ONE platform migration run `SELECT * FROM _pay_apply_schema_upgrades(); SELECT * FROM _pay_ensure_reference_data();`. The gateway never alters an
   existing table; `_pay_apply_schema_upgrades` is additive and idempotent and brings any earlier build (including pre-release builds) to the current shape. New tables need nothing.
   Run it before any order or capture traffic. Create each issuer and series, and adopt live series from their last used number (`_inv_series_adopt`).
2. **Entitlement cutover** (replacing a legacy subscriptions table), in this order: set the platform's missing mode (`pay-entitlement missing-mode`); `import-legacy`; move EVERY legacy writer
   (subscription functions, signup, webhooks, trial start) to `ent_*` / `pay_apply_capture`; then, in one window with the legacy writers stopped, `import-legacy --sync` (the delta import) and
   **`_ent_cutover_check`** (`pay-entitlement cutover-check`), which raises unless the verifier returns zero differences, no legacy row is invalid and the missing modes agree. Only then rename the legacy
   table to an archive and create the compatibility view `ent_legacy_subscriptions`. See README, "Cutover runbook".
3. **Wallet opening balances.** `_wlt_import_opening_balances` (idempotent; counts but never rewrites a changed balance), then the reconciliation gate **`_wlt_verify_opening`** (`pay-wallet verify-opening`)
   before any v2 traffic; then `_wlt_mark_platform_migrated`. Create packs with `_wlt_pack_create`.
4. **Wire the schedulers** (one line each): `pay-entitlement billing-run`, `pay-entitlement tick`, `pay-wallet expire`, `pay-wallet verify-ledger`, `pay-purge-webhooks`, `pay-refund-queue-alerts`, `pay-replay-webhooks`.

### Features

- **L7.0** idempotent reference data, generated from the seeders. **L7.1** issuers, series, gapless per-FY numbering, a structurally separate TEST series, immutable issued invoices.
- **L7.2** durable webhook inbox (ack only after persist, replay, dead rows, alerts, 13-month raw-payload redaction with audit). **L7.3** orders, `pay_order_quote`, the single exactly-once `pay_apply_capture`,
  the refund queue with ageing alerts, `fetchPayment`, an admin apply path that verifies with the gateway first.
- **L7.4** one entitlement store (`ent_*`): audited idempotent comp activation, the postpaid monthly cycle with 30-day read-only and same-transaction restore, per-platform missing mode, the access
  middleware with bounded fail-open, billing periods in Asia/Kolkata computed from the anchor, back-off and alerts for billing failures.
- **L7.5** wallet v2: capture-bound idempotent top-up, locked idempotent hard-stop drain, drift-free `wallet_drain_cumulative` metering, FIFO-by-expiry, milli-credits, expiry as a policy switch (default off),
  double-entry ledger with `_ledger_verify`.
- **CA/LEGAL TO CONFIRM before relying on these in production:** the 13-month raw-payload and 8-year accounting-record retention periods; the financial year and time of supply for a payment received in
  one FY and invoiced in the next, and whether a receipt voucher is required (CGST s.13(2), s.31(3)(d)); the CGST/SGST remainder rounding; the 40% GST slab and the legacy 12%/28% marking; the 30-day
  read-only threshold and postpaid invoicing in arrears; wallet credit expiry terms and the GST/accounting treatment of forfeited credit (expiry is OFF until the customer terms say so).

### Detailed change log (by work item)


### L7.0 preconditions (no behaviour change)

- New `_pay_ensure_reference_data()` (`src/Core/Schema/functions/050_50_*`):
  idempotent, additive convergence of the 14 reference tables, generated from
  the seeders by `scripts/generate-reference-data.php`. Lets a database that was
  created before the package, or only partly seeded, reach a verified state with
  one platform migration. See README, "Reference data".
- Review fixes: gateways are seeded and ensured INACTIVE (no placeholder endpoint is ever live); GST slab 40% added, 12%/28% marked legacy (CA to confirm).
- `tests/run-suite.sh` now fails the run when a strict test file fails and runs
  `tests/shell/l7_*.sh` (multi-database tests) after the SQL files.
- `tests/rehearsal/gateway_migrate.sh`: real-gateway rehearsal harness.

### L7.1 issuers, series, gapless lawful numbering, TEST series

- New tables `inv_issuers`, `inv_series`, `inv_series_counter`, `inv_series_adoptions`;
  new nullable columns on `inv_invoices` (issuer, series, FY label, serial, mode, document
  date, seller and buyer snapshots); `inv_invoices.invoice_number` becomes nullable (drafts).
- New functions `_inv_issuer_upsert`, `_inv_series_create`, `_inv_series_allocate`,
  `_inv_series_adopt`, `_inv_series_format_number`, `_inv_series_head`, `_inv_in_fy_label`.
- `inv_issue_invoice` gains trailing `p_series_code` and `p_mode` (the explicit-number path is
  unchanged); `inv_transition_invoice_status` allocates the number at the draft -> issued edge.
  The function signature changed: replaced via the gateway's normal drop-and-recreate.
- Row guards: immutable issued invoices (number, amounts, snapshots, lines; no delete),
  forward-only counters, immutable series definitions, append-only adoption log, TEST/live
  agreement between mode and number.
- `_pay_apply_schema_upgrades()` upgrades existing `inv_invoices` tables in place; the gateway
  never alters an existing table.
- Review fixes: status-regression and delete bypass closed; legacy NULL mode = live with back-fill; lines INSERT/re-point guarded;
  back-fill only on legacy rows; adopt FY validation + dry run; allocator callable only while issuing + `inv_series_gap_audit()`;
  explicit-number rules; document-date window (`issue_date_window_days`); PY040 schema-behind check; TRUNCATE guards;
  CGST/SGST remainder rounding (accepted divergence from the PHP oracle, CA to confirm); draft edge re-validation.
- **Upgrade steps for a platform on 0.1.x:** add one migration calling
  `_pay_apply_schema_upgrades()` and `_pay_ensure_reference_data()`; create its issuer and
  series; `_inv_series_adopt` each live series from its last used number. See README.

### L7.2 durable webhook inbox, ack-only-after-persist, replay

- New table `pay_webhook_inbox` and functions `pay_webhook_record`, `pay_webhook_claim`,
  `pay_webhook_mark`, `pay_webhook_replay_candidates` (+ retention guard). New tables need no
  upgrade step: the gateway creates them.
- `WebhookEvent` gains `eventId` (Razorpay: `x-razorpay-event-id`; PayPal: the event `id`) and
  `toArray()` / `fromArray()`. New `MalformedWebhookException` (a `WebhookException` subclass the
  Razorpay driver throws only AFTER the signature verified, so a signed-but-unreadable body can be
  stored raw instead of dropped).
- Review fixes: `dead` terminal status + exponential backoff + fewest-attempts-first replay (no starvation); exact foreign /
  unattributed classification; alerts stamped only after the sink succeeded; dedupe key = SHA-256 of the signed body; drivers
  catch post-verification parse failures as `MalformedWebhookException`; PayPal verification splices the ORIGINAL body and caches
  the OAuth token; `PaymentProvider::webhookSignatureHeader()` (no `''` default); rate-limiter hook; privacy: normalised event
  only (no payload / duplicate raw), 13-month redaction of raw bodies with audit (`_pay_webhook_redact_expired`,
  `bin/pay-purge-webhooks`), new `pay_config` table (CA/legal to confirm the periods).
- New `StoneScriptPay\Http\Webhook` module (`WebhookIngress`, `SqlWebhookInboxStore`,
  `PlatformRoutingProcessor`, `WebhookReplayer`, alert sink) and the framework route
  `StoneScriptPay\Http\Routes\PostWebhookRoute`; `bin/pay-replay-webhooks`. The framework is a soft
  dependency, as for `InvoiceSourceAdapter`.

### L7.3 orders, idempotent order creation, the single `pay_apply_capture`, `fetchPayment`

- New tables `pay_orders`, `pay_events`; new functions `pay_order_create`,
  `pay_order_attach_gateway_order`, `pay_order_get`, `_pay_order_quote` (+ spec helpers),
  `pay_apply_capture` (+ immutability guards). New tables need no upgrade step.
- **Contract change (breaking for implementers of `PaymentProvider`):** `mode()`,
  `publishableKeyId()` and `fetchPayment(): PaymentDetails` were added; both drivers implement
  them. `RazorpayDriver` takes optional `$mode` and `$paymentFetcher`; `PaypalDriver` takes an
  optional `$transport`. `WebhookEvent` gains `orderRef`.
- New PHP: `OrderService`, `OrderRequest`, `CaptureApplier`, `CaptureWebhookProcessor`,
  `AdminPaymentApplier`, `PaymentNotConfirmedException`.
- Review fixes: `pay_refund_queue` + `refund_required` / `captured_not_applied` outcomes; the invoice is numbered into the FY of
  the issue moment (`p_issued_at`); gateway-order creation lease + Razorpay lookup-by-receipt + PayPal request ids; PayPal
  server-side capture after approval (`ServerSideCapture`, `OrderService::completeApproval`); `fetchPayment` id validation and
  refund awareness; allow-listed non-personal `raw_payload` + body hash; capture time = gateway's, else event time, flagged;
  order/invoice freeze and forward-only status; TRUNCATE guards; events carry the mode; NULL mode = live in `pay_order_create`.
  `pay_apply_capture` gained a trailing `p_issued_at`. Contract additions: `findOrderByReceipt()`.
- **Fixed (existing defect):** `inv_invoice_payability` raised `record "v_gw" is not assigned yet`
  whenever the first call on a database session was for an invoice that was NOT payable (already
  paid, or not yet due): the function read a RECORD that is only assigned on the payable path. It
  worked in the test suite only because an earlier call in the same session had assigned it. A
  pooled connection can hit this in production. It now uses scalar variables.

### Delta review (all three trains)

- **Setup and migration functions are now internal (leading underscore)** so a gateway that refuses underscore names cannot be
  asked to run them from the network: `_pay_ensure_reference_data`, `_pay_apply_schema_upgrades`, `_pay_config_int`, `_inv_in_fy_label`,
  `_inv_assert_schema_current`, `_inv_series_*`, `_inv_issuer_upsert`, `_pay_order_spec_buyer/_lines/_quote`. **Rename: update the one-line
  platform migration** (`SELECT * FROM _pay_apply_schema_upgrades(); SELECT * FROM _pay_ensure_reference_data();`). The README lists
  the public, privileged and internal functions.
- Issue-date window is per mode: `issue_date_window_days_live` (default 0: a live document is dated today, IST) and
  `issue_date_window_days_test` (7). The single `issue_date_window_days` key is gone.
- `_inv_series_allocate` refuses unless `pay.issuing` is on (PY041); the 25-argument `inv_issue_invoice` call shape is
  rehearsed on a real gateway (the old overload is dropped, no 42725).
- `pay_apply_capture`: mismatching and unknown-order captures are queued in `pay_refund_queue` (`review_mismatch`, `unattributed`)
  and return `refund_required` / `unattributed` instead of raising, so money never lives only in the inbox; PY033 still raises.
  A redelivery is checked first, so it can never queue already-applied money. `p_raw` passes through the server-side allow-list
  `_pay_capture_raw_allowlist` (the PHP `RawPayloadAllowlist` mirrors it; arbitrary JSON cannot be stored).
- Refund-queue ageing: `pay_refund_queue_aged`, `pay_refund_queue_alert_sent`, `RefundQueueMonitor`, `bin/pay-refund-queue-alerts`,
  config `refund_queue_alert_after_days` (3) / `refund_queue_alert_repeat_hours` (24), column `pay_refund_queue.last_alert_at`
  (added to existing tables by `_pay_apply_schema_upgrades`). `_pay_webhook_redact_expired` skips transactions with an open
  refund-queue entry or an unapplied capture.
- `_pay_webhook_requeue` clears both alert stamps; the redaction guard requires the `pay.redacting` flag and an audit row.
- **Round-3 review:** `_pay_refund_queue_resolve`, `_pay_webhook_requeue` and `_pay_webhook_redact_expired` are now internal and run
  only from the server CLIs (`bin/pay-refund-queue-resolve`, `bin/pay-webhook-requeue`, `bin/pay-purge-webhooks`) over the platform's
  direct database credentials, never `/call`; `--actor` is required and logged. New public read-only `pay_order_quote` (tenant-scoped
  price breakdown, equal to what `pay_order_create` enforces; create now also refuses a series of another platform or tenant).
  PHP/SQL raw-allowlist parity is proved by a 66-case data provider.
- README: the FY / receipt-voucher question is spelled out as CA-to-confirm; the entry-point list and the redaction decision are documented.

### L7.4 entitlement, comp activation, postpaid cycle, access middleware

- New tables `ent_entitlements` (THE entitlement store), `ent_activations` (append-only audit with per-activation idempotency keys),
  `ent_billing_runs`; new functions `ent_get`, `ent_comp_activate`, `ent_start_trial`, `ent_set_status`, `ent_enroll_postpaid`,
  `ent_billing_run`, `ent_tick`; internal `_ent_effective`, `_ent_apply_period`, `_ent_import_legacy`, `_ent_verify_legacy`, `_pay_config_text`;
  compatibility view `ent_legacy_subscriptions`; trigger restoring a postpaid entitlement when its invoice is paid, in the same transaction.
- `pay_apply_capture` now sets the entitlement (subscription_period stacks remaining time; one_time_license is lifetime); a postpaid
  entitlement receiving a period payment is queued for refund (`entitlement_conflict`) instead of being absorbed.
- New config rows: `ent_past_due_after_days` (0), `ent_read_only_after_days` (30), `ent_missing_mode` (read_only), `ent_billing_catchup_max_periods` (12).
- PHP: `EntitlementGuard` (pure), `EntitlementMiddleware` (framework adapter; 423 with the existing error codes + `READ_ONLY_PAYMENT_OVERDUE`).
- Migration: `_ent_import_legacy` + `_ent_verify_legacy` (zero differences) + the compatibility view. See README, "Entitlement".
- **Review fixes (L7.4):** admin and scheduled entry points are internal (`_ent_comp_activate`, `_ent_set_status`, `_ent_enroll_postpaid`, `_ent_set_billing_mode`,
  `_ent_billing_due`, `_ent_billing_run_one`, `_ent_tick`) with one server tool `bin/pay-entitlement` (actor required, logged) and `EntitlementOperations` for a platform's own
  authorised admin route; caller-supplied moments are bounded to the database clock (`PY064`); the middleware queries the MAIN database, normalises object rows, and fails
  open only on transport errors with a 10-minute last-known-decision cache, alerting on repeated failures and on deploy errors; billing periods are `anchor + n x interval` in
  `billing_timezone` (Asia/Kolkata); the tick works in cursor batches; billing is one entitlement per transaction with exponential back-off and an `ENT_BILLING_FAILED` alert;
  a postpaid tenant cannot buy a period order and an operator can switch prepaid <-> postpaid; a payment for a suspended entitlement is queued (`paid_while_suspended`); a late
  apply never costs paid time (`ent_late_apply_grace_hours`); the library's own money routes are on the default write allow-list; `_ent_cutover_check` is the hard cutover gate and
  `ent_missing_mode` is per platform; the delta import (`--sync`) carries legacy renewals; a legacy row with no end is expired at its cancellation time.
  Delta-review fixes: an explicit NULL time passed to a defaulted time parameter means "now" (`_ent_import_legacy`, billing, tick, `ent_get`), and PHP passes the database clock; the library's
  own routes are mounted under ONE prefix, `/pay` (`RoutePaths`), and only that prefix is on the default write allow-list (it follows a configured prefix); the deploy-alert throttle lives in the
  shared cache; a billing failure in the setup (a poison row) is recorded with back-off like any other, and PHP catches per entitlement; periods are counted from the CURRENT billing anchor
  (postpaid -> prepaid -> postpaid re-switch); `--as-of` is clamped; `--sync` compares the CURRENT legacy row with the entitlement (change-then-revert syncs); `_pay_apply_schema_upgrades` brings a
  pre-release database up (tested from the 1053b42 shape; `_ent_billing_due` / `_ent_billing_fail` are plpgsql because the gateway deploys functions before it alters tables); the
  `bin/pay-entitlement` command line parses its own options (PHP's `getopt` stops at the command).
  New config: `pay_clock_skew_seconds`, `billing_timezone`, `ent_late_apply_grace_hours`, `ent_billing_backoff_base_seconds`, `ent_billing_backoff_cap_seconds`.

### L7.5 wallet v2 and the ledger

- New tables `wlt_wallets`, `wlt_grants`, `wlt_drains`, `wlt_drain_allocations`, `wlt_forfeits`, `ledger_txns`, `ledger_entries`; new functions
  `wallet_balance`, `wallet_drain`, `wallet_grant_free`, `wallet_forfeited`, `wallet_expire`, `_ledger_verify`; internal `_wlt_topup`, `_wlt_wallet_lock`,
  `_wlt_forfeit_expired`, `_wlt_import_opening_balances`, `_ledger_post`.
- `pay_apply_capture` credits wallet top-ups through `_wlt_topup` (bound to the capture, milli-credits). **The v1 `wallet_*` functions are deprecated** and no longer
  fed by the capture path. `wallet.credited` events now carry `granted_milli` and `wallet_id`.
- New config: `wallet_milli_per_credit` (1000), `wallet_expiry_enforced` (0: purchased credit does not expire until the customer terms say so).
- **Delta-review fixes (L7.5):** `_ledger_verify` is internal (cross-tenant) with `pay-wallet verify-ledger`; an out-of-order OLDER meter tick is a recorded no-op (`superseded`) and
  `_wlt_meter_close` retires a meter for a reset or rate change (a closed meter refuses ticks); the meter contract and "ticks carry usage_at = now" are documented; schema-upgrade steps
  for the wallet columns and the widened ledger kinds; `bin/pay-wallet` parses its own options.
- **Review fixes (L7.5):** wallet packs carry an explicit credit amount (`wlt_packs`, `_wlt_pack_create`; no division at capture); an unfulfillable paid top-up is queued as
  `wallet_unfulfillable` and returns `refund_required` instead of failing; `wallet_drain_cumulative` is the drift-free metering entry point; opening-balance import counts
  changed balances (`o_changed`), sorts by tenant, and `_wlt_verify_opening` is the reconciliation gate; future usage and sweep dates are clamped (`pay_clock_skew_seconds`),
  `granted_at = least(captured_at, now())`; the expiry sweep is one wallet per transaction (`_wlt_expire_due` / `_wlt_expire_one`); wallets, grants and meters are guarded
  against rewriting; `wallet_milli_per_credit` is immutable once credit exists; v1 wallet functions raise for a migrated platform (`_wlt_mark_platform_migrated`); ledger kinds
  refund / reversal / clawback; minting entry points (`_wlt_grant_free`) and the sweep are internal with `bin/pay-wallet` and `WalletOperations`.

## v0.1.0

**Structural merge:** `stonescriptphp-pay` (Razorpay/PayPal gateway transport
drivers, the `pay_captured_payments`/`pay_record_captured_payment` idempotent
capture primitive) and `stonescriptphp-invoice` (this package's SQL-first
Pricing/Metering/Tax/Invoicing/Outbox) are now ONE repo/package/version —
owner-directed 2026-09-22. See `README.md` for the merged architecture.
Completed the in-flight `Gst` -> `Tax/India` bucket-layout migration (deleted
the superseded linear `src/Gst/Schema/main/`) and fixed two load-order bugs
the half-finished split had left behind — see `LOAD-ORDER.md`.

**Identity alignment to `the auth service` (breaking schema change):**
every identity-bearing table/function now takes `tenant_id UUID` +
`platform_code VARCHAR(50)` — matching `the auth service`'s own
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
