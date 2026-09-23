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
composer test                 # PHP driver/DTO/adapter unit tests
PSQL='psql -h localhost -U postgres' DB=payments_suite ./tests/run-suite.sh   # full SQL suite
```

SQL-suite green = the differential golden reports **failed = 0** (1036/1036),
every `ok_*` is `t`, and every negative case prints its `ok: ER###` line.

## License

MIT — see `LICENSE`.
