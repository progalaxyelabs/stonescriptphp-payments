# stonescriptphp-payments

The **unified payment system** for [StoneScriptPHP](https://stonescriptphp.org).
This single package merges what used to be three separately-versioned pieces —
`stonescriptphp-pay` (gateway transport drivers), `stonescriptphp-invoice`
(SQL-first billing/invoicing), and the glue between them — into **one repo, one
composer package, one version, one schema load-order, one test suite**. There is
no longer a "which package owns this" question for payment capture, invoicing,
or tax: it's all here.

Three cooperating layers:

1. **Drivers** (`src/Drivers/`) — thin PHP transport for payment gateways
   (Razorpay, PayPal today). Create orders, verify checkout responses, parse
   webhooks. No business logic — every driver implements the shared
   `PaymentProvider` contract.
2. **Capture** (`src/Capture/Schema/`) — the canonical, idempotent
   payment-**capture** SQL primitive (`pay_captured_payments` +
   `pay_record_captured_payment()`). Records "this gateway transaction was
   captured, exactly once" and nothing else — no wallet credit, no
   subscription extension, no invoice transition. A consumer's own domain
   function composes its side effect on top of it (see that function's
   docblock for the exact composition contract).
3. **Invoicing/Pricing/Metering/Tax/Outbox** (`src/Invoicing/`, `src/Pricing/`,
   `src/Metering/`, `src/Tax/`, `src/Outbox/`, `src/Php/InvoiceSourceAdapter.php`)
   — SQL-first billing: plans, subscriptions, wallets, credit ledgers,
   passthrough cost-plus, postpaid charges, persisted invoices, configurable
   invoice numbering, parties, a **pluggable regional tax layer** (ships a
   ready India-GST-compatible implementation under `Tax/India`), data-driven
   gateway routing, and the durable transactional-outbox intimation to a
   central merchant-of-record. Business logic lives in PostgreSQL functions
   deployed via the StoneScriptDB Gateway — PHP is transport only.

## Architecture: logic in Postgres, PHP is transport only

Ecosystem law for StoneScriptPHP is that business logic lives in SQL functions
(one tested place, one fix lands once) and PHP is a thin transport/packaging
layer. Money is **integer minor units** (paisa/cents) end to end; quantity is
integer milli-units; fx-rate is a decimal string — never a float.

```
src/Contracts/, src/DTO/, src/Exceptions/, src/Drivers/   # gateway transport (PHP)
src/Capture/Schema/{tables,functions}/NNN_*.pgsql         # idempotent capture primitive (SQL)
src/<Feature>/Schema/{tables,functions,types,views,seeders}/NNN_*.pgsql
                                                            # billing/invoicing schema, bucketed (one object per file)
src/Php/InvoiceSourceAdapter.php                           # the ONE invoicing-side PHP file — a transport shim
tests/Unit/                                                 # PHP driver/DTO unit tests
tests/php/                                                   # PHP marshalling tests for InvoiceSourceAdapter (Database::fake(), no live DB)
tests/sql/NNN_*.psql                                         # SQL test suite (scenarios, seeds, golden regression, negatives)
tests/run-suite.sh                                            # loads everything in canonical order, reports the golden tally
LOAD-ORDER.md                                                 # THE canonical SQL load order (global numeric prefix) — read this
```

**Multi-country tax (scaffolded, not yet wired):** `inv_tax_scheme` +
`inv_resolve_tax_scheme()` (033, `src/Tax/Schema/`) resolve which tax regime
governs a billing country by a plain JOIN — the SAME pattern
`inv_resolve_gateway` already uses for payment-gateway routing (data +
JOIN + a `CASE` on a data column), never a dynamically-dispatched/EXECUTEd
function name. Today exactly one scheme is seeded (`'IN' -> 'in_gst'`), and
`inv_compute_invoice` (030, `Tax/India`) IS that scheme's engine, called
directly and statically as before — this table is additive scaffolding so
the next country is a data `INSERT` (+ at most one new hardcoded `CASE`
branch in a future country-agnostic dispatcher), never a new
"pass a function name" parameter anywhere.

Features: **Pricing** (plans, customers, subscription core), **Metering**
(wallet, credit ledger, passthrough cost-plus, postpaid, subscription+overage),
**Tax/India** (the included India-GST regional tax pack — money primitives,
state/region codes, config/slabs, invoice-number formatter, party, line/invoice
validation, tax engine, dated-FX reference value), **Invoicing** (persisted
invoices, payments, gateway routing, status lifecycle, CRM chase projection),
**Outbox** (transactional-outbox product<->central intimation, both
directions), **Capture** (the gateway-agnostic idempotent capture primitive).
Swap `Tax/India` for your own region's tax pack to bill under different rules.

All SQL schema is the **`main`** scope; a per-tenant scope layer is deferred.

## Framework compatibility

The SQL, the drivers and the pure-PHP classes (`EntitlementGuard`, `EntitlementOperations`, `WalletOperations`, the webhook ingress and inbox) need no framework. The
**framework adapters require StoneScriptPHP >= 12.0** and are tested against 12.0.0: `Entitlement\EntitlementMiddleware` and `FrameworkMainDbScope` (tenant-context handling over the
gateway client), `Webhook\DatabaseFnCaller` (`Database::fn`, and `Database::mutate` for the functions you name: the 12.0 write boundary, off by default), `Routes\PostWebhookRoute`, and
`Php\InvoiceSourceAdapter`. The library passes only scalar arguments to `Database::fn`, so the 12.0 raw-array deprecation never fires; its routes answer with their own `ApiResponse`
(no exception text reaches a client), register `POST` only (the 12.0 `HEAD` and `405` rules do not affect them), and every tenant id it handles is a UUID (the 12.0 tenant-id rule).
Do not pin a platform to an older framework to use these adapters.

## Installation

```bash
composer require progalaxyelabs/stonescriptphp-payments
```

## Driver usage

```php
use StoneScriptPay\Drivers\RazorpayDriver;
use StoneScriptPay\DTO\CreateOrderRequest;
use StoneScriptPay\DTO\VerifyRequest;
use StoneScriptPay\DTO\WebhookRequest;

// Instantiate — credentials are runtime-injected from env, never hardcoded
$provider = new RazorpayDriver(
    keyId:         $_ENV['RAZORPAY_KEY_ID'],
    keySecret:     $_ENV['RAZORPAY_KEY_SECRET'],
    webhookSecret: $_ENV['RAZORPAY_WEBHOOK_SECRET'],
);

// 1. Create an order (server-set amount — never trust client)
$order = $provider->createOrder(new CreateOrderRequest(
    amountMinorUnits: 49900,   // paise for INR
    currency:         'INR',
    receipt:          'order_ref_001',
    notes:            ['tenant_id' => $tenantId],
));
// Pass $order->orderId and $order->publishableKeyId to the frontend

// 2. Verify the checkout response from the frontend
$result = $provider->verifySignature(new VerifyRequest(
    paymentId: $request->razorpay_payment_id,
    orderId:   $request->razorpay_order_id,
    signature: $request->razorpay_signature,
));
// $result->verified === true → safe to fulfil the order

// 3. Handle webhooks
$event = $provider->handleWebhook(new WebhookRequest(
    rawBody:   file_get_contents('php://input'),
    signature: $_SERVER['HTTP_X_RAZORPAY_SIGNATURE'] ?? '',
));
if ($event->isPaymentCaptured()) {
    // Record the capture (see "Capture primitive" below), then fulfil
}
```

### The `PaymentProvider` contract

Every driver implements `settlementModel(): string`, returning `'gateway'`
(the consuming application is merchant of record and owes GST/tax invoicing —
Razorpay, PayPal) or `'mor'` (the provider is seller of record and handles tax
itself — e.g. a future Paddle driver). Framework glue such as
`StoneScriptPHP\Billing\CollectionOrchestrator` uses this to decide whether an
invoicing side (`InvoiceSource`) is expected.

### PayPal driver

`PaypalDriver` ports a bespoke PayPal Orders v2 client (raw curl, no SDK) into
the shared contract — one-time order/capture only, PayPal Subscriptions is NOT
implemented (`createSubscription()` / `cancelSubscription()` /
`getSubscription()` throw `PaymentException`).

**`verifySignature()` is NOT side-effect-free for this driver — calling it
actually CAPTURES the order (moves funds).** PayPal's Orders v2 flow has no
signature distinct from capture, so the capture call itself IS the
authoritative confirmation. It is idempotent against retries (a deterministic
`PayPal-Request-Id` header, plus explicit handling of a 422
`ORDER_ALREADY_CAPTURED` response as success rather than a signature failure)
— but know that this method performs a real, funds-moving API call before you
call it from anywhere that might retry blindly.

```php
use StoneScriptPay\Drivers\PaypalDriver;
use StoneScriptPay\DTO\WebhookRequest;

$provider = new PaypalDriver(
    baseUrl:      $_ENV['PAYPAL_BASE_URL'],      // e.g. https://api-m.sandbox.paypal.com
    clientId:     $_ENV['PAYPAL_CLIENT_ID'],
    clientSecret: $_ENV['PAYPAL_CLIENT_SECRET'],
    webhookId:    $_ENV['PAYPAL_WEBHOOK_ID'],
);

// verifySignature() differs from Razorpay's model: PayPal has no
// client-returned HMAC distinct from capture, so this driver performs the
// CAPTURE call itself inside verifySignature() and reports success only if
// it completed. Pass '' for VerifyRequest::$paymentId/$signature (unused);
// only $orderId is read.

// handleWebhook() needs PayPal's multiple PAYPAL-TRANSMISSION-* headers
// (not one HMAC header like Razorpay) — pass them via WebhookRequest::$headers:
$event = $provider->handleWebhook(new WebhookRequest(
    rawBody:   file_get_contents('php://input'),
    signature: '',
    headers:   getallheaders() ?: [],
));
```

Known gap: minor-unit <-> decimal-string conversion assumes a 2-decimal
currency (USD/EUR/INR/...) — a 0-decimal currency (e.g. JPY) is not supported
as written.

## Capture primitive

`pay_record_captured_payment()` is THE canonical, safe-by-default idempotent
capture primitive for the whole StoneScriptPHP ecosystem. Call it as the
**first statement** of your own domain function (e.g. an activation or credit
function), inside the same transaction, before performing your own side
effect:

```sql
SELECT * FROM pay_record_captured_payment(
    p_gateway_code    => 'razorpay',
    p_gateway_txn_ref => 'pay_ABC123',
    p_reference       => my_order_ref,
    p_amount_minor    => 49900,
    p_currency        => 'INR',
    p_status          => 'success',
    p_captured_at     => now(),
    p_created_by      => 'webhook:razorpay'
);
-- o_already_applied = false -> this call is the exactly-once winner, perform
--   your side effect (extend a subscription, credit a wallet, ...) NOW, in
--   this same transaction.
-- o_already_applied = true  -> a replay (webhook retry, or a losing race) —
--   do not repeat the side effect; return your idempotent response from
--   current domain state.
```

Idempotency key is `(gateway_code, gateway_txn_ref)` — a plain `UNIQUE` index
plus `INSERT ... ON CONFLICT DO NOTHING` is the entire concurrency guarantee
(no advisory lock, no row lock — see the function's docblock for why that's
sufficient). Deploy `src/Capture/Schema/` alongside the rest of this package's
schema.

## Invoicing side: `InvoiceSourceAdapter`

`src/Php/InvoiceSourceAdapter.php` implements
`StoneScriptPHP\Billing\Contracts\InvoiceSource` (published by
`progalaxyelabs/stonescriptphp` v9.17.0+'s `Billing\` seam) by calling
`inv_invoice_payability` / `inv_record_payment` via `Database::fn()`. It is
pure marshalling — it computes no amount, tax, or routing decision; every
value it returns is one the SQL function already decided. Wire it into
`StoneScriptPHP\Billing\CollectionOrchestrator` to drive automated collection:

```php
use StoneScriptPHP\Billing\CollectionOrchestrator;
use StoneScriptPHP\Billing\Contracts\GatewayCode;
use StoneScriptPHP\Invoice\Php\InvoiceSourceAdapter;
use StoneScriptPay\Drivers\RazorpayDriver;

$orchestrator = new CollectionOrchestrator(
    payment: new RazorpayDriver($keyId, $keySecret, $webhookSecret),
    invoices: new InvoiceSourceAdapter(createdBy: 'webhook:razorpay'),
    gatewayCode: GatewayCode::RAZORPAY,
);
```

This is **optional** — `progalaxyelabs/stonescriptphp` is only `suggest`-ed
(+ `require-dev` for this package's own tests), not `require`d. Pure-SQL usage
(issue invoices, run the CRM chase, mark paid manually) and the payment-driver
side need nothing but PHP itself.

## Deploy

Load every `src/**/*.pgsql` file in the global numeric-prefix order (see
`LOAD-ORDER.md`) — in a StoneScriptPHP project this is the StoneScriptDB
Gateway migration path (`php stone gateway:migrate`). The schema loads
standalone into an empty database with no test/seed dependency:

```bash
PSQL='psql -h localhost -U postgres' DB=payments ./tests/run-suite.sh --schema-only
```

### Issuers, numbering series and lawful invoice numbers

Statutory serial numbers (CGST Rules 2017, Rule 46(b): consecutive, at most 16
characters, letters / numerals / hyphen / slash, unique per financial year, in
one or several series) are allocated by the library, never by the caller:

```sql
-- once per seller of record, and once per numbering series
SELECT _inv_issuer_upsert('acme', 'myplatform', NULL, 'Acme Pvt Ltd', 'regular',
                         '29AAACX1234C1ZP', '29', 'address', false, 'actor');
SELECT _inv_series_create('acme-inv',  'acme', 'invoice', 'live', 'AB',    '/', 5, true, 'actor');  -- AB/26-27/00001
SELECT _inv_series_create('acme-test', 'acme', 'invoice', 'test', 'TESTA', '/', 4, true, 'actor');  -- TESTA/26-27/0001

-- every invoice: pass the series and the mode, leave the number NULL
SELECT inv_issue_invoice(NULL, ..., p_series_code => 'acme-inv', p_mode => 'live');
```

- **Gapless.** The counter row is incremented under its row lock in the same
  transaction as the invoice insert. A rollback releases the number; concurrent
  issuances serialise per series. A Postgres sequence is never used. Issuance
  therefore serialises per series (about one invoice per series per
  commit round-trip), which is far above invoice volumes; shard by series, never
  by giving up gaplessness.
- **Per financial year.** With `fy_reset` the counter restarts each Indian FY
  (1 April - 31 March, taken in IST whatever the session time zone) and the FY
  label is part of the number; without it one counter continues for ever. The
  document date passed to `inv_issue_invoice` decides the year.
- **Within 16 characters, at creation.** `_inv_series_create` rejects a series whose
  longest possible number could exceed the maximum length or leave the charset, and
  a series that runs out of serials refuses to issue instead of minting a longer one.
- **TEST can never share a series with live.** A test series' prefix must start with
  `TEST` and a live one's never does; `mode` is mandatory when issuing and must equal
  the series' mode (`PY012`), so a test document can never draw a live number nor a
  live one a test number; the invoice row guard checks the same thing again.
  A series' head (`prefix || sep`) may not be a prefix of another series' head.
- **Placeholder issuers.** A live series refuses to issue while its issuer is still a
  placeholder (`PY013`); a placeholder can own test series only.
- **Seller and buyer snapshots.** The invoice stores the seller (from the issuer) and
  buyer as issued; editing the issuer later never rewrites an issued document.
- **Drafts take no number.** A series invoice opened as `draft` has no number; it is
  allocated on the draft -> issued edge (`inv_transition_invoice_status`), so an
  abandoned draft burns nothing.
- **Immutable once issued.** An issued invoice's number, amounts, document type, seller
  and buyer snapshot and lines cannot be updated, and it cannot be deleted (`PY019`):
  void or cancel it, the number stays in the books. Counters only move forward.
- **Continuing an existing series.** `_inv_series_adopt(series, fy, last_used, evidence,
  actor)` sets the counter to the last number already used elsewhere, so the next
  library number is exactly last + 1. It refuses to move backwards or below a serial
  already stored (`PY018`), requires evidence and an actor, and is logged in
  `inv_series_adoptions`. Existing numbers are never renumbered.
- **Explicit numbers still work** (`p_invoice_number`, no series) for importing
  documents numbered elsewhere; such rows have `series_id` NULL and carry no gapless
  guarantee.

**Review hardening (all enforced in SQL, all tested):**

- *Status.* Only the legal edges of `inv_invoice_status_transitions` are accepted, so an issued invoice can never
  be set back to `draft` (which would make it deletable and its number reusable); `DELETE` of any non-draft is refused.
- *Legacy rows.* Invoices issued before this release have `mode` NULL. Every mode check treats NULL as **live**, and
  `_pay_apply_schema_upgrades()` back-fills `mode`: `test` only when the number is provably a TEST number, `live` otherwise.
  A test-mode order can therefore never settle a legacy live invoice. A NULL snapshot column may be back-filled on a
  legacy row (series_id NULL) only; a series-issued row is never back-filled.
- *Lines.* Lines cannot be added to, moved out of or re-pointed between issued invoices. `charge_ref`, SAC and the period
  are frozen with the amounts. `TRUNCATE` of the retained tables is refused.
- *Explicit numbers* must carry a mode, may not fall inside any series' head, and a TEST string never lands in a live row.
- *No burning serials.* `_inv_series_allocate` refuses direct calls (PY041); only the issuing functions can allocate.
  `inv_series_gap_audit()` lists every serial missing from the books (adopted ranges excluded) and any invoice beyond a counter.
- *Document date window.* A series-numbered document must be dated within a window of today (IST calendar days, PY042):
  `issue_date_window_days_live` (default **0** = today only) for a live series, `issue_date_window_days_test` (default 7) for a test
  series. **Why 0 for live:** a statutory document is dated the day it is issued; the failure to prevent is a mistyped or stale
  date putting a serial into the wrong financial year, or out of order across 1 April, and a window of even a few days still allows
  exactly that near 31 March. **Date-order implication:** since a live document is dated the day it is numbered, the serial order is
  the date order (to the day) within a series. History enters through the explicit-number import path, which does not allocate and
  is exempt (recognisable by `series_id` NULL). A deployment that really needs a wider live window sets the configuration row,
  knowingly.
- *Adopt* validates the FY label (second year = first + 1, within one year of the current FY) and has a dry run.
- *Draft edge* refuses to number a draft whose seller registration/GSTIN/state changed, or whose GST rate is no longer an allowed slab (PY015).
- *Schema behind.* Functions that need the upgraded schema raise PY040 naming the missing migration instead of a raw column error.
- *GST rounding.* A line's total tax is rounded once; CGST is half rounded half-up, SGST the remainder, so the heads always sum to the
  rounded total (no paisa over-billed). This deliberately differs from the PHP reference on odd totals (56 recorded, accepted divergences
  in the golden suite). **CA to confirm** that a one-paisa CGST/SGST difference is acceptable.

SQLSTATEs: `PY010` not found, `PY011` inactive / wrong kind, `PY012` mode,
`PY013` placeholder issuer, `PY014` invalid definition, `PY015` seller conflicts with
issuer, `PY016` number/series combination, `PY017` exhausted or counter behind,
`PY018` counter backwards, `PY019` immutability, `PY040` schema upgrade missing, `PY041` direct allocation, `PY042` document date outside the window.

> **Load-bearing: run `_pay_apply_schema_upgrades()` before ANY order or capture traffic** on a database that already held invoices.
> The numbering functions, row guards and the capture path need the columns it adds; until it has run they refuse with `PY040` naming
> the missing migration (a write in that window fails loudly and is retried; nothing is corrupted). Deploy order: gateway migrate (which
> runs the platform's migration containing the call) first, application traffic second.

### Upgrading a database that already holds invoices: `_pay_apply_schema_upgrades()`

The gateway creates a table from its file only when the table is missing; it never
alters an existing one (new columns, a relaxed NOT NULL or a new index in a table file
are reported as safe but not applied). New tables need nothing. For tables that already
exist the library ships an additive, idempotent function, run from the platform's own
migration together with the reference-data one:

```sql
SELECT * FROM _pay_apply_schema_upgrades();
SELECT * FROM _pay_ensure_reference_data();
```

It returns one row per change it made (none when current). Run the migrate at a quiet
moment: the gateway deploys functions (including the new row guards) before it runs
migrations, so for the length of that one request a write to `inv_invoices` can fail
loudly until the columns exist.

### Webhooks: a durable inbox, acknowledged only after it is stored

`StoneScriptPay\Http\Webhook\WebhookIngress` is the endpoint logic (framework-independent);
`StoneScriptPay\Http\Routes\PostWebhookRoute` is the StoneScriptPHP route over it (register
it as a **public** route: the gateway's signature, verified by the driver, is the authentication).

```php
$ingress = new WebhookIngress(
    ['razorpay' => new WebhookGateway('razorpay', new RazorpayDriver($keyId, $keySecret, $webhookSecret), 'x-razorpay-signature')],
    new SqlWebhookInboxStore(new DatabaseFnCaller()),            // pay_webhook_* SQL functions via the gateway
    new PlatformRoutingProcessor('myplatform', $myProcessor),    // foreign / unattributed routing + your idempotent handler
    $alertSink,                                                  // optional; defaults to error_log
);
```

1. The driver verifies the signature **before** parsing. A bad one is `401` and writes nothing.
2. The event is stored (`pay_webhook_record`) - the durability point. If that fails the answer is
   `503`, the gateway redelivers, and the event is applied exactly once when it finally arrives.
3. Only then is it processed and acknowledged. A processing failure leaves a `failed` row (kept,
   replayable, alerted **once**) and still answers `200`: the event is durable, a retry would only
   redeliver a duplicate.

| outcome | meaning |
|---|---|
| `applied` | processed; the processor must be idempotent (it can be re-run after a crash) |
| `ignored` | a verified event type with no handler |
| `foreign` | addressed to another platform on a shared gateway account (read from the order notes): recorded, never applied, never alerted |
| `unattributed` | a payment event with no platform routing key: recorded, **never applied by guess**, alerts once |
| `failed` | processing raised, or a signed body was unreadable (stored raw, byte for byte) |

The classification is exact: an event carrying **our platform code but no order of ours**, or one of **our order
references that does not resolve**, is `unattributed`; an event with **no routing key and no order of ours at all** (someone
else's payment on a shared gateway account) is `foreign` - recorded, never replayed, never alerted.

**Dedupe key = SHA-256 of the raw body**, the bytes the gateway's signature covers. The gateway's own event id travels in an
unsigned header (Razorpay), so a forged id could pre-empt another event's genuine delivery or let an old signed body dodge
dedupe; a genuine redelivery is byte-identical, so it still dedupes. The header id is kept as metadata.

**Replay cannot starve.** An open row (`failed` / `unattributed`) is retried with exponential backoff
(`webhook_backoff_base_seconds` doubling, capped), fewest attempts first, and after `webhook_max_attempts` attempts or
`webhook_dead_after_days` days it becomes **`dead`**: terminal, never claimed or replayed, alerted once on that transition
(`_pay_webhook_requeue` puts it back by hand). Every alert is stamped as sent (`pay_webhook_alert_sent`) only after the sink
succeeded, so a failing sink leaves it due instead of consuming it. All of these are `pay_config` rows.

**Rate limiting.** The route is public until the signature is verified, and PayPal verification costs an outbound call.
`WebhookIngress` takes an optional `RateLimiter` and answers `429` before verifying anything; the library ships none (it cannot
assume a shared store) - back it with the counter the platform already uses, or an `nginx limit_req` zone in front.
The PayPal OAuth token is cached until a minute before it expires (and refreshed once on a 401).

#### What is stored where (privacy)

| Data | Where | Personal data? | Kept |
|---|---|---|---|
| Normalised webhook event (event type, gateway payment id, order ref, amount, currency, tenant, platform, time) | `pay_webhook_inbox.event` | no | with the inbox row |
| Raw webhook body | `pay_webhook_inbox.raw_body` | **may** (payer e-mail, phone, card/UPI details as the gateway sent them) | `raw_payload_retention_months` (default **13**), then redacted to a record holding only its SHA-256 and the normalised event; each redaction audited in `pay_webhook_redactions` |
| Provider-native payload / duplicated raw body inside the stored event | not stored | - | - |
| Request headers | `pay_webhook_inbox.headers` | no (allow-list; anything credential- or signature-like is dropped) | with the row |
| Buyer name / GSTIN / state on an invoice | `inv_invoices.buyer_*` | yes (statutory) | `accounting_record_retention_years` (8 financial years, Companies Act s.128); **never** touched by the payload job |
| Payments, orders, events | `inv_payments`, `pay_captured_payments`, `pay_orders`, `pay_events` | allow-listed non-personal fields + body hash only | accounting records |

Legal bases (**CA / legal to confirm both periods**): the DPDP Rules 2025 impose a minimum one-year retention for personal data,
traffic data and processing logs, so raw payloads are kept 13 months (floor + buffer; also covers card-dispute windows) and then
redacted by `bin/pay-purge-webhooks` (daily cron/systemd); accounting records are statutory for 8 financial years. The retention
period of raw payloads is an owner decision; 13 months is the default. Both are `pay_config` rows.

A redelivered event (same signed bytes) is a no-op.
Rows are retained records: never deleted, evidence columns immutable. Two deliveries (or a delivery
and a replay) cannot process one event at once: a short lease is claimed first.

Replay re-drives `failed`, `unattributed` and stale `received` rows with `WebhookReplayer`, or from
cron / systemd with `vendor/bin/pay-replay-webhooks --bootstrap=replayer.php` (the bootstrap file returns
your configured `WebhookReplayer`; exit status 2 while any row is still open). Existing deployments
that run a bespoke quarantine table can copy its rows into the inbox as `failed` / `unattributed` rows
with `pay_webhook_record(..., 'failed', <error>)` so nothing already captured is lost.

### Orders and the single exactly-once capture path

Every payment starts as a server-created **order** and ends in one function, `pay_apply_capture`.
There is no second copy of "capture exactly once" to keep in step: the webhook processor, the
operator path and any reconciliation job all call it.

```php
$orders = new OrderService($db, ['razorpay' => $razorpayDriver]);
$view = $orders->create(new OrderRequest(
    tenantId: $tenant, platformCode: 'myplatform', idempotencyKey: $clientKey,   // the retry key
    gatewayCode: 'razorpay', purpose: OrderRequest::SUBSCRIPTION_PERIOD,
    amountMinorUnits: 58882, currency: 'INR',
    catalogRef: (string) $planId, seriesCode: 'acme-inv', invoiceSpec: [...],    // what to invoice
));
// $view->orderRef, ->gatewayOrderId, ->publishableKeyId for the hosted checkout; poll $orders->status(...)

$processor = new PlatformRoutingProcessor('myplatform', new CaptureWebhookProcessor(new CaptureApplier($db), ['razorpay' => $razorpayDriver]));
```

- **Price before the order: `pay_order_quote`.** A checkout or pricing page calls `pay_order_quote(tenant, platform, series, spec, currency)`
  (public, read-only, tenant-scoped; the series must belong to the platform and be visible to the tenant) and gets the line and
  tax breakdown, the total and an `o_orderable` flag. `o_gross_minor` is exactly the amount `pay_order_create` enforces for the same
  inputs (both read one computation), so showing it and creating the order with it can never be refused for a mismatch. It writes
  nothing and allocates no number. `pay_order_create` applies the same tenant/platform scoping to its series.
- **Idempotent creation.** One idempotency key names one request: the same key and request
  returns the same order (and the same gateway order); a different request under the key is
  refused (`PY036`). A failed gateway call leaves a retryable order; a retry never makes a second
  gateway order, and two racing identical requests end with the same order.
- **The server fixes the amount; the library re-proves it.** For `subscription_period`,
  `one_time_license` and `wallet_topup` the order carries an invoice spec; the invoice the spec
  produces must total exactly the order amount (`PY034`) at creation and again at capture. A
  live order is refused while its issuer is a placeholder (`PY013`): money is never taken for an
  invoice that cannot be issued. For `invoice_payment` the invoice must exist, be payable, belong
  to the tenant and match the amount.
- **Mode from the credentials.** `PaymentProvider::mode()` is read from the key id prefix
  (`rzp_test_` / `rzp_live_`) or the PayPal host and is never assumed; a capture in the other mode
  is refused (`PY031`), and the invoice is numbered from a series of the order's mode.
- **Routing from the order, never a guess.** The order reference travels in the gateway notes
  (`order_id`, `platform_code`, `tenant_id`). A capture for an unknown order is `unattributed` and
  writes nothing.
- **One transaction.** `pay_apply_capture` records the capture (idempotent primitive), issues the
  invoice from the order spec (next gapless number), marks it paid, applies the purpose
  (`subscription_period` renews, stacking remaining time; `one_time_license` enrols the plan;
  `wallet_topup` credits a grant for the taxable value; `invoice_payment` settles the existing
  invoice), marks the order paid and appends `payment.applied` (+ `entitlement.changed` /
  `wallet.credited`) to `pay_events`. If anything raises, nothing at all is written - no invoice,
  no number, no payment, no entitlement. A redelivery is `already_applied` with the original ids.
- **Never applied, never lost.** A NEW transaction whose amount, currency, tenant, platform, gateway or mode disagrees with
  the order it names is not applied and is not raised away either: it is written to `pay_refund_queue` (reason
  `review_mismatch`) and the call returns `refund_required`, so real money never lives only in the retention-limited webhook
  inbox. An order reference of ours that matches no order is queued as `unattributed` (the call still returns `unattributed`; a
  capture carrying no reference at all is a foreign payment and is not queued). The one thing that still raises is a
  transaction already recorded and re-reported against another order or with another amount (`PY033`): that money is already
  accounted for, so queueing it for refund would be wrong.
- **Money that cannot be applied is visible, never absorbed.** A capture for an order that is already paid or cancelled, or
  for an invoice that was voided or paid meanwhile, rolls the attempt back and writes a `pay_refund_queue` entry (committed),
  returning `refund_required`; the webhook processor fails the inbox row so it alerts. A human refunds it and closes the entry
  with `_pay_refund_queue_resolve`. **Ageing:** an entry still open after `refund_queue_alert_after_days` (3) is alerted by
  `RefundQueueMonitor` / `bin/pay-refund-queue-alerts` (kind `refund_queue.aged`, stamped only after the sink succeeded, repeated
  every `refund_queue_alert_repeat_hours`, 24, until resolved). The retention job never redacts the raw webhook body of a
  transaction that has an open refund-queue entry or a recorded capture whose order is not paid. A capture row that exists while its order is **not** paid returns `captured_not_applied`
  (alerted), never `already_applied`.
- **Financial year of a late capture.** The invoice is dated, and numbered into the FY of, the **issue moment** (`p_issued_at`,
  default now), not of the gateway's capture time: a payment received on 31 March but applied on 2 April is invoiced in the new
  FY, so a number never goes out of order across 1 April. The payment keeps the gateway's capture time as `paid_at`. The document
  date must be within the mode's issue window of now. **CA TO CONFIRM (not a legal conclusion):** (1) a payment received in
  FY n and invoiced in FY n+1: under CGST s.13(2) the time of supply of an advance is the earlier of the invoice date and the
  receipt, so the tax point may be the receipt date; (2) whether CGST s.31(3)(d) then requires a **receipt voucher** for the
  advance, in its own series, issued on receipt, with the invoice following later; (3) whether using the issue moment as the
  invoice date is acceptable. Until the CA answers, the library numbers the invoice into the FY of its issue moment (a number
  never goes out of order across 1 April) and stores the gateway's capture time as the payment's `paid_at`; it does not issue
  receipt vouchers. If the CA requires them, that is a separate document type and series, not a change to this rule.
- **Capture time.** Razorpay's webhook carries no capture timestamp: the event's creation time is used, then the payment's
  creation time, and either is flagged `:capture-time-estimated` in the audit source; PayPal reports the capture's own time.
- **Gateway order creation is single-flight.** `pay_order_begin_gateway_create` is a lease so one of several concurrent identical
  requests creates the gateway order; the others wait and are handed it. Razorpay is asked for an existing order with our receipt
  first; a PayPal create carries a `PayPal-Request-Id` derived from the order reference. **PayPal orders** complete through
  `OrderService::completeApproval()`: the server captures the approved order (`captureApprovedOrder`, request id = the order
  reference, so a retry cannot double-charge) and the result goes through the same apply path as the webhook.
- **Operator path.** `AdminPaymentApplier` asks the gateway (`PaymentProvider::fetchPayment`)
  before applying anything: the payment must be captured, for exactly the order's amount and
  currency, against the order's own gateway order. Otherwise `PaymentNotConfirmedException` and
  nothing is written. When confirmed it goes through the same function, so it stays exactly-once
  with a webhook that arrives later. Authorising the operator is the platform's job: pass the **authenticated operator id from the platform's own session** as `$actor`, never a typed or client-supplied value; it is the audit trail (`admin:<id>`). A payment id must look like `pay_...` (checked before it reaches an API path), and a **partly refunded** payment is refused unless `$allowPartiallyRefunded` is set explicitly.
- **Events.** `pay_events` is append-only and written in the same transaction as its cause; a
  platform reacts to a payment by reading rows past a persisted id cursor, not by overriding
  the library.

#### Which functions are entry points (what a platform may call, and what it may not)

A SQL function reachable through the gateway's `/call` is an API. This package therefore marks its own setup and migration acts
as **internal** with a leading underscore, so a gateway that refuses underscore names (StoneScriptDB Gateway 4.8+) cannot be
asked to run them from the network, and the public surface is exactly the functions below.

- **Internal (leading underscore; run from a migration or an operator database session, never exposed):**
  `_pay_ensure_reference_data`, `_pay_apply_schema_upgrades`, `_pay_config_int`, `_inv_in_fy_label`, `_inv_assert_schema_current`,
  `_inv_series_head`, `_inv_series_format_number`, `_inv_series_allocate`, `_inv_series_adopt`, `_inv_series_create`,
  `_inv_issuer_upsert`, `_pay_order_spec_buyer`, `_pay_order_spec_lines`, `_pay_order_quote`, `_pay_queue_refund`, `_pay_webhook_requeue`, `_pay_refund_queue_resolve`, `_pay_webhook_redact_expired`,
  `_pay_capture_raw_allowlist`, `_pay_config_text`, `_ent_apply_period`, `_ent_effective`, `_ent_emit`, `_ent_overdue`, `_ent_overdue_cutoff`,
  `_ent_import_legacy`, `_ent_verify_legacy`, `_ent_comp_activate`, `_ent_set_status`, `_ent_enroll_postpaid`, `_ent_set_billing_mode`, `_ent_set_missing_mode`,
  `_ent_cutover_check`, `_ent_billing_due`, `_ent_billing_run_one`, `_ent_tick`, `_pay_bound_clock`, `_pay_clamp_future`, `_pay_db_now`. Operator and scheduler actions have a
  CLI: see "Admin actions" under Entitlement. `_wlt_topup`, `_wlt_wallet_lock`, `_wlt_forfeit_expired`, `_wlt_grant_free`, `_wlt_import_opening_balances`, `_wlt_verify_opening`, `_wlt_expire_due`, `_wlt_expire_one`,
  `_wlt_mark_platform_migrated`, `_wlt_meter_close`, `_ledger_post`, `_ledger_verify`. A platform that needs one in a request route wraps it in its own SQL function with its own
  authorisation. Trigger functions are not directly callable.
- **Public entry points (called by application code):** `inv_issue_invoice`, `inv_transition_invoice_status`, `inv_record_payment`,
  `inv_invoice_payability`, `inv_resolve_gateway`, `inv_series_gap_audit`, `pay_record_captured_payment`, `pay_webhook_record`,
  `pay_webhook_claim`, `pay_webhook_mark`, `pay_webhook_alert_sent`, `pay_webhook_replay_candidates`, `pay_order_create`,
  `pay_order_quote`, `pay_order_attach_gateway_order`, `pay_order_get`, `pay_order_begin_gateway_create`, `pay_order_end_gateway_create`,
  `pay_apply_capture`, `pay_refund_queue_aged`, `pay_refund_queue_alert_sent`, `ent_get`, `ent_start_trial`, `wallet_balance`, `wallet_drain`,
  `wallet_drain_cumulative`, `wallet_forfeited`.
- **Operator actions: internal AND CLI-only (leading underscore, never reachable over `/call`):** `_pay_webhook_requeue`,
  `_pay_refund_queue_resolve`, `_pay_webhook_redact_expired`. They are run by a command-line tool on the server with the
  platform's **direct database credentials**, never through the gateway: `bin/pay-webhook-requeue`,
  `bin/pay-refund-queue-resolve` (both require `--actor`, which is written to the audit trail and echoed to stderr) and
  `bin/pay-purge-webhooks`. Each takes the platform's own bootstrap file that returns the configured PHP object
  (`WebhookRequeuer`, `RefundQueueResolver`, `WebhookRetention`) over a direct `SqlFunctionCaller`. An in-app admin screen for
  these is the platform's own SQL wrapper function with its own authorisation, not a library route.

`_pay_webhook_redact_expired` can only redact rows that are already final and past the retention period, never deletes
anything, skips any transaction with unresolved money (above), and the inbox guard refuses any redaction that lacks the
`pay.redacting` flag and its audit row in `pay_webhook_redactions`. It is still kept off `/call`: retention is a
scheduled-job concern, not a network API.

### Entitlement: one store, comps, the postpaid cycle, the access middleware

`ent_entitlements` is the **one** answer to "what is this tenant entitled to, and until when" (the framework's legacy `subscriptions`
table and the pricing history in `customer_pricing_plans` are not consulted for access; the library writes the history in the same
transaction). Everything reads `ent_get(tenant, platform, product)`: the access middleware, an offline-licence reader, a scan-credit
reader.

- **Facts, not flags.** The row stores facts (a period end, a billing mode, the invoices billed to it); the *effective* status
  (`trial | active | past_due | read_only | ended | suspended`) is derived at the moment of the question by one function
  (`_ent_effective`), so a missed scheduler tick can never grant or deny access wrongly. `_ent_tick` only persists the transitions
  and appends `entitlement.changed` events; it works in cursor batches until every row has been examined.
- **Periods stack, in the billing zone.** A paid or comped period starts at the later of "now" and the current end. All period arithmetic is
  done in the billing zone (`pay_config.billing_timezone`, **Asia/Kolkata**, the billing jurisdiction), whatever the session TimeZone.
  `pay_apply_capture` sets the entitlement in the capture's own transaction (`pay:<order_ref>` is the idempotency key).
- **A late apply never costs paid time.** A backlog or a replay can apply a capture hours or days after the gateway captured it. The period is
  anchored at the later of the capture time and the previous period end; if the apply happens more than `ent_late_apply_grace_hours` (24) after the
  capture it is anchored at the apply time, so the customer always receives the full period they paid for.
- **A payment for a suspended entitlement goes to a human.** A suspension may be for abuse, fraud or a chargeback, so a payment neither reinstates
  access silently nor is absorbed: `pay_apply_capture` returns `refund_required`, queues it as `paid_while_suspended` (alerted like every refund-queue
  entry) and issues nothing; an operator decides (reinstate, then apply by hand, or refund). A comp for a suspended entitlement is recorded and the
  suspension stands.
- **Postpaid** (`_ent_enroll_postpaid`, the billing run): one invoice per period **in arrears** with the next gapless number of the profile's series
  (live or test), issued and moved to `due`. **Periods are `anchor + n x interval` in the billing zone, never chained**: a 31 January anchor bills
  to 28/29 February, then 31 March, 30 April, ... and back to 31 January. Unpaid for `ent_past_due_after_days` (0) after the due date = `past_due`
  (writes still allowed); unpaid for `ent_read_only_after_days` (**30**) = `read_only`. **Paying the invoice restores access in the payment's own
  transaction**, by any path. No auto-debit. A postpaid tenant cannot buy a `subscription_period` or `one_time_license` order (`PY061`): it pays its
  invoices. `_ent_set_billing_mode` (operator) switches an entitlement between prepaid and postpaid, refusing while an invoice is unpaid.
- **The billing run is one entitlement per transaction** (`bin/pay-entitlement billing-run`): the series counter lock is held for one invoice's work and
  released, never across the whole run. A failing entitlement is rolled back (no invoice, no number), recorded, **backed off exponentially**
  (`ent_billing_backoff_*`) and reported as `ENT_BILLING_FAILED` (logged, and alerted as `entitlement.billing_failed`); the others carry on.
- **Annual prepay** is a subscription plan of 12 months sold through an order. **Trial** (`ent_start_trial`): one per tenant, for the trial plan's duration.
- **No entitlement row** follows the platform's missing mode: pay_config `ent_missing_mode:<platform>` (`read_only` | `allow`), else the global
  `ent_missing_mode` (`read_only`, the framework's default).
- **Clock.** A caller-supplied moment is bounded to the database clock: a comp, a status change or a trial start further than `pay_clock_skew_seconds`
  (300) from `now()` is refused (`PY064`); a billing anchor may be in the past (a migration; catch-up is bounded to 12 periods per run) but not in the future.

**Who may call `ent_get`.** `ent_get` (and, below, the `wallet_*` functions) take a tenant id and trust it: they are for the **platform's server code**, called with the
tenant the platform has just authenticated (the JWT's), never with an id from a request body or a URL. Exposing them through a route that accepts a
tenant id from the caller would let one tenant read another's entitlement and balance.

#### Admin actions: internal functions, CLI, and your own authorised route

The functions that give access away or move money-adjacent state are **internal** (leading underscore) and never reachable over the gateway's `/call`:
`_ent_comp_activate`, `_ent_set_status`, `_ent_enroll_postpaid`, `_ent_set_billing_mode`, `_ent_set_missing_mode`, `_ent_import_legacy`, `_ent_cutover_check`,
and the scheduled `_ent_billing_due` / `_ent_billing_run_one` / `_ent_tick`. Two ways to use them:

1. **The server tool** `bin/pay-entitlement <command>` (comp, status, enroll-postpaid, billing-mode, missing-mode, import-legacy, cutover-check, billing-run,
   tick) with the platform's **direct database credentials**. Every mutating command requires `--actor`, which is written to the audit trail and logged.
   The scheduler lines are `pay-entitlement billing-run` and `pay-entitlement tick`; the clock comes from the database (`--as-of` is for rehearsals only).
2. **The platform's own admin route.** The library authenticates no one. A platform that wants an in-app "comp this account" button writes a route that
   authenticates and authorises the operator itself, then calls `EntitlementOperations::comp(...)` (or the matching method) over its **direct** database
   connection, passing the authenticated operator id as `$actor`. Never wire an internal function to a route through the gateway client.

#### The access middleware

`StoneScriptPay\Http\Entitlement\EntitlementMiddleware` (framework adapter) over `EntitlementGuard` (pure PHP): reads `ent_get` on the **main**
database (`FrameworkMainDbScope` clears the tenant context for the call and restores it, like the framework's own middleware), lets reads through, refuses
writes by a read-only tenant with **HTTP 423** and the error code (`READ_ONLY_TRIAL_EXPIRED | READ_ONLY_PLAN_ENDED | READ_ONLY_PAYMENT_OVERDUE |
READ_ONLY_NO_SUBSCRIPTION`), and sets `X-Subscription-State`. The write allow-list keeps the framework's (renewal, export, data erasure, account recovery) **plus the
library's own money routes**, which all live under ONE namespaced prefix, **`/pay`** (`RoutePaths`: `/pay/orders`, `/pay/payments`, `/pay/quote`, `/pay/webhook/{gateway}`), so a read-only tenant can always pay. `/pay` is the only library entry on the default write allow-list: no generic `/orders` or `/payments` is allowed on the library's behalf, so a platform's own routes of that name are not accidentally exempt. A platform that mounts the library elsewhere passes its prefix to `EntitlementGuard` (and to `RoutePaths`) and the allow-list follows it.

**Bounded fail-open.** Infrastructure trouble must not lock customers out, but a blip must not make a lapsed tenant writable. On a TRANSPORT failure the
middleware serves the **last-known decision** for that tenant (up to 10 minutes) and otherwise serves open; after N consecutive failures it alerts once
(`entitlement.lookup_failing`). A DEPLOY failure (`ent_get` missing, `PY050`, an empty result) is a bug, not a blip: logged at ERROR as
`ENTITLEMENT_DEPLOY_ERROR`, alerted (`entitlement.deploy_error`) and still served. On every fail-open path **no** `X-Subscription-State` header is sent.

#### Cutover runbook: replacing a legacy subscriptions table

The hard rule: **the view replaces the table only after every legacy writer has moved to `ent_*`.** A legacy table that is still being written
while a view stands in for it silently loses those writes.

1. Set the platform's missing mode to match the legacy platform's (`pay-entitlement missing-mode --platform P --mode ...`).
2. `pay-entitlement import-legacy --legacy subscriptions` (idempotent, audited; a non-UUID tenant or unknown status is counted invalid, never guessed).
3. Move **every** legacy writer to `ent_*` / `pay_apply_capture`: the `sub_*` functions, signup, webhooks, trial start. Deploy it.
4. In ONE window: stop the legacy writers, run `pay-entitlement import-legacy --legacy subscriptions --sync` (the **delta import**: renewals written to the legacy
   table after the first import are carried over; an entitlement that has since moved on in `ent_*` is left alone), then
   `pay-entitlement cutover-check --legacy subscriptions --platform P --legacy-missing-mode ...`. The check **raises (`PY067`)** unless the verifier returns zero
   differences, no legacy row is invalid, and the missing modes agree.
5. Only then rename the legacy table to an archive (never dropped by this package) and `CREATE VIEW subscriptions AS SELECT * FROM ent_legacy_subscriptions`.

A legacy row with no `expires_at` is treated as already expired at its cancellation time (a cancelled row with no end is `ended`, never active forever).

### Wallet v2: idempotent, locked, FIFO, milli-credits, double-entry

Prepaid credit with a **hard stop at zero**. The v1 `wallet_*` functions (`topup_wallet`, `grant_free_credits`, `record_wallet_drain`) remain for
platforms that have not migrated but are **deprecated**: no lock, no idempotency key, whole credits only. `pay_apply_capture` no longer uses them.
`_wlt_mark_platform_migrated(platform)` (or `pay-wallet mark-migrated`) is the per-platform switch: from then on those v1 functions **raise** (`PY074`) for
that platform, so nothing can mint or debit the old wallet behind the new one's back.

- **Packs carry an explicit credit amount.** A wallet *pack* (`wlt_packs`, created by `_wlt_pack_create`: plan active, credits > 0, validity a pair)
  grants N credits. There is **no division at capture time**: the amount paid does not decide the credits, so a GST-inclusive or discounted price cannot make
  a paid top-up unfulfillable. `pay_order_create` refuses an order for a pack that is inactive, whose plan is inactive, or that grants nothing.
- **A paid top-up never fails silently.** If, by capture time, the pack was withdrawn or anything else makes the credit impossible (`ER013/ER014/ER015/PY070/PY071`),
  `pay_apply_capture` rolls the attempt back (no invoice, no number), queues the money as `wallet_unfulfillable` and returns `refund_required`: visible, alerted,
  never left in the inbox.
- **Top-up is bound to a capture.** `_wlt_topup` (internal; only the capture path calls it) refuses unless a successful captured payment exists, keys the grant
  `cap:<gateway>:<txn>` (replaying the capture credits **once**) and posts to the ledger. `granted_at = least(capture time, now())`.
  `_wlt_grant_free` (internal, `pay-wallet grant-free`) is the audited, idempotent promotional grant.
- **Milli-credits.** Credit is stored as BIGINT milli-credits; the display unit is defined once (`pay_config.wallet_milli_per_credit` = 1000) and **cannot change
  once any credit exists** (it would silently re-denominate every balance).
- **`wallet_drain(tenant, platform, drain_key, milli, usage_at, reason, actor)`** is serialised per wallet (row lock), idempotent per `drain_key` (the tick id),
  all-or-nothing, and returns `insufficient` (writing nothing) when the spendable balance is short: **it never overdraws**; what to stop at zero is the domain's
  decision. A drain spanning grants consumes the earliest-expiring first. `usage_at` is clamped to `now() + pay_clock_skew_seconds`.
- **`wallet_drain_cumulative(tenant, platform, meter_key, tick_key, cumulative, rate_num, rate_den, usage_at, reason, actor)` is THE metering entry point**
  (a per-minute compute tick, a scan counter). The caller reports the meter's **cumulative** usage and the rate as a fraction (milli-credits per unit); the wallet
  debits `floor(cumulative x rate) - already debited for that meter`, so the total is always **exactly** `floor(total usage x rate)`, never the sum of per-tick
  roundings (which drifts). A repeated tick returns its original answer; cumulative may not go backwards or the rate change (use a new meter key); if the balance
  cannot cover the delta the answer is `insufficient`, nothing is written and the meter does not advance, so the next tick asks for the whole shortfall.
  **The meter contract.** A meter has one rate for life and cumulative usage that only grows. An OLDER cumulative under a new tick key (an at-least-once queue delivering
  out of order) is a no-op, outcome `superseded` (recorded, charges nothing: the newer tick already covered it). A meter **reset** (the resource restarted from zero) or a **rate
  change** is not a late tick: retire the meter with `_wlt_meter_close` (`pay-wallet close-meter`) and use a NEW `meter_key`; a closed meter refuses new ticks (`PY071`).
  **Ticks carry `usage_at` = now**; a retried tick is identified by its tick key, not its timestamp, and re-sending an old attempt's time asks the wallet about a past moment
  (which can resurrect credit that has since expired). **Only platform server code may call `wallet_*` and `ent_get`, with the tenant it has authenticated;** never expose them
  through a route that takes a tenant id from the caller.
  A platform that bills per-minute usage (a workspace that runs while credits last) calls this each minute and stops the resource on `insufficient`.
- **Expiry is a policy switch, default OFF.** `pay_config.wallet_expiry_enforced` = 0 means purchased credit never expires, whatever a pack says; set it to 1 (a
  data change, once the customer terms say so) and a top-up expires after its pack's validity. A free grant with an explicit expiry always expires. Credit is not
  spendable from the **exact** expiry instant, and expired credit is **forfeited and reported** (`wallet_forfeited`), never deleted. The sweep
  (`pay-wallet expire`) forfeits **one wallet per transaction** in small batches and ignores future dates. A drain dated before an expiry that has *not yet been
  swept* may still use that credit; once swept it is gone and a backdated drain is refused for it. Forfeiture's GST/accounting treatment is for the CA to confirm.
- **Double-entry ledger.** Every credit, debit and forfeiture is a posting that sums to zero (immutable, balance enforced at commit; kinds topup, free_grant, opening,
  drain, forfeit, and refund / reversal / clawback reserved for credit notes); `_ledger_verify()` returns only violations (zero rows = sound); it is **internal** (it returns rows across all tenants) and runs as `pay-wallet verify-ledger`, nightly.
- **Opening balances.** `_wlt_import_opening_balances(rows, scale, actor)` imports one migration grant per wallet in (tenant, platform) order, rejects (never rounds)
  sub-milli, negative or non-UUID rows, is idempotent, and **counts** (`o_changed`) a legacy balance that moved since the first import instead of rewriting a posted
  balance. `_wlt_verify_opening(rows, scale)` is the **reconciliation gate**: it returns only the wallets whose spendable balance differs from the legacy balance
  (zero rows = they reconcile to the last milli-credit); run it right after the import and before any v2 traffic. `pay-wallet verify-opening` exits 1 on any difference.
- **Admin actions are internal + CLI**, like the entitlement ones: `bin/pay-wallet` (grant-free, create-pack, import-opening, verify-opening, mark-migrated, expire, close-meter, verify-ledger;
  `--actor` required and logged) or `WalletOperations` from the platform's own authorised admin route over a direct database connection.

### Reference data: `_pay_ensure_reference_data()`

The StoneScriptDB Gateway seeds reference rows only when it **creates** a
database. On a database that already exists, `migrate` merely verifies them and
fails with `MISSING SEEDER RECORDS` when any are absent, which is exactly the
state of a database created before this package was staged (or one whose seeding
stopped part-way). Add one migration to the consuming platform's own migrations:

```sql
SELECT * FROM _pay_ensure_reference_data();
```

It inserts every missing reference row (14 tables, foreign-key order) and nothing
else: existing rows are never updated or deleted, so local edits survive, and a
second run changes nothing. Gateways are seeded **inactive**: their checkout endpoint is a placeholder, so a deployment sets the real
endpoint and activates the gateways it uses. The GST slab set includes 40% (GST 2.0) and keeps 12% / 28% only
for historical documents (`legacy_rate_slabs`); the set is a tax judgement for the CA to confirm. It returns one row per table with the number of rows
it inserted, so an operator can see what was missing. The gateway applies a
migration file once, so a package release that adds reference rows needs one new
migration of the same one-liner. The function is generated from the seeders by
`scripts/generate-reference-data.php` (`--check` is part of the test suite), so
the seeders stay the single source of truth.

## `now()` defaults

Every timestamp that is genuinely "the moment this happens" (`created_at`, a
transition instant, a relay's as-of) carries `DEFAULT now()` — a production
caller omits it and the module supplies the time itself; the module never
depends on the API to pass "now". Genuine business inputs stay **required**:
`issue_date`, `due_date`, billing-period bounds, the gateway's own
`captured_at`/`paid_at`, and each usage/measurement instant. The SQL test
suite pins **explicit** timestamps so it stays deterministic;
`039_test_now_defaults.psql` proves the omit-and-default path.

## Security

- **Backend is the verification authority** — amount is set server-side; the
  frontend only receives `order_id` and the publishable `key_id`.
- **Secrets are runtime-injected** — `key_secret` and `webhookSecret` are
  never in source.
- **Hosted checkout only** — card details never pass through your app
  (Razorpay's/PayPal's hosted surface).
- **Capture is idempotent by construction** — see "Capture primitive" above.

## Test

```bash
composer test                 # PHP driver/DTO/adapter/webhook unit tests (the real-SQL ones SKIP without PAYMENTS_TEST_PG_DSN)
PSQL='psql -h localhost -U postgres' DB=payments_suite ./tests/run-suite.sh   # full SQL suite
```

SQL-suite green = the differential golden reports **failed = 0** (1036/1036),
every `ok_*` is `t`, and every negative case prints its `ok: ER###` line. After
the SQL files, `run-suite.sh` runs the multi-database and multi-process tests in
`tests/shell/` (each creates and drops its own `paytest_*` databases on the same
server; set `SKIP_SHELL_TESTS=1` to skip) and exits non-zero if any strict test
fails. They need `PGBENCH` (the complete pgbench command incl. host/user), and
`PAY_PHP_IMAGE` (a PHP docker image with `pdo_pgsql`: `docker build -t payments-php-pg -f
tests/docker/php-pg.Dockerfile tests/docker`) with `PAY_VENDOR_DIR` / `PAY_FRAMEWORK_DIR` /
`PAY_DB_*` as described at the top of `tests/shell/l7_2_webhook_inbox.sh`; a missing
prerequisite fails the run, it is never a silent skip.

`tests/rehearsal/gateway_php_tests.sh` runs the real-SQL PHP tests through a gateway's `/call` (typed JSON parameters, as a deployed platform does) instead of over PDO; the gateway keeps SQLSTATEs out of its HTTP answers, so those tests identify refusals by the SQL's own message there.

`tests/rehearsal/gateway_migrate.sh` drives a **real, disposable** StoneScriptDB
Gateway through register / create / migrate on a fresh, a pre-existing and a
partially seeded database, three migrate passes each. Never point it at a shared
or production gateway.

## License

MIT — see `LICENSE`.
