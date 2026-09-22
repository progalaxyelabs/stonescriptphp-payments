<?php

declare(strict_types=1);

namespace Tests;

use PHPUnit\Framework\TestCase;
use StoneScriptPHP\Billing\Contracts\RecordPaymentRequest;
use StoneScriptPHP\Database;
use StoneScriptPHP\Invoice\Php\InvoiceSourceAdapter;

/**
 * Marshalling-level tests for InvoiceSourceAdapter, the sole PHP file in
 * this package (see its class docblock). Exercises it against
 * Database::fake() closures that faithfully reproduce
 * `inv_invoice_payability`/`inv_record_payment`'s DOCUMENTED contract
 * (idempotent replay by gateway_txn_ref, single due->paid transition,
 * amount/currency-match guard) — as read directly from
 * `src/Invoicing/Schema/functions/035_04_inv_record_payment.pgsql` and
 * `src/Invoicing/Schema/functions/035_05_inv_invoice_payability.pgsql`.
 *
 * This is deliberately NOT a live-Postgres/gateway integration test —
 * Tier-3 SQL correctness (the real idempotency guarantee, the partial
 * unique index, ER05x error codes) is already covered by
 * `tests/sql/036_test_invoices_payments_gateway.psql` against a real
 * database. What THIS test proves is narrower and PHP-specific: does the
 * adapter call `inv_record_payment`/`inv_invoice_payability` with the
 * RIGHT positional argument order, and does it map the result rows into
 * PayableIntent/RecordPaymentResult without inventing or altering any
 * value — i.e. that it is pure marshalling, per the ecosystem law that
 * business logic lives in SQL, never in this PHP shim.
 */
class InvoiceSourceAdapterTest extends TestCase
{
    protected function tearDown(): void
    {
        Database::clearFakeMode();
    }

    /**
     * Minimal in-memory stand-in for one inv_invoices row + its
     * inv_payments, driving fake() closures that reproduce
     * inv_invoice_payability()/inv_record_payment()'s documented rules.
     */
    private function fakeInvoiceState(): array
    {
        return [
            'status' => 'due',
            'gross_total_minor' => 49900,
            'currency' => 'INR',
            'gateway_code' => 'razorpay',
            'checkout_endpoint' => 'https://pay.example.com/inv_1',
            'payments' => [], // "{gateway_code}|{gateway_txn_ref}" => payment id
            'next_payment_id' => 1,
        ];
    }

    private function installFakes(array &$state): void
    {
        Database::fake([
            'inv_invoice_payability' => function (array $params) use (&$state) {
                $invoiceId = $params[0];
                $hasSuccess = false;
                foreach ($state['payments'] as $p) {
                    if ($p['status'] === 'success') {
                        $hasSuccess = true;
                    }
                }
                if ($state['status'] === 'paid' || $hasSuccess) {
                    $payable = false;
                    $reason = 'already_paid';
                } elseif ($state['status'] === 'due') {
                    $payable = true;
                    $reason = 'payable';
                } else {
                    $payable = false;
                    $reason = 'not_payable_status';
                }

                return [[
                    'invoice_id' => $invoiceId,
                    'is_payable' => $payable,
                    'status' => $state['status'],
                    'reason' => $reason,
                    'gross_total_minor' => $state['gross_total_minor'],
                    'currency' => $state['currency'],
                    'gateway_code' => $payable ? $state['gateway_code'] : null,
                    'checkout_endpoint' => $payable ? $state['checkout_endpoint'] : null,
                ]];
            },
            'inv_record_payment' => function (array $params) use (&$state) {
                [$invoiceId, $tenantId, $platformCode, $gatewayCode, $gatewayTxnRef, $amountMinor, $currency, $status, $capturedAt, $createdBy] = $params;

                $key = "{$gatewayCode}|{$gatewayTxnRef}";
                if (isset($state['payments'][$key])) {
                    // idempotent replay — return the existing id, change nothing.
                    return [['inv_record_payment' => $state['payments'][$key]['id']]];
                }

                if ($status === 'success') {
                    if ($currency !== $state['currency'] || $amountMinor !== $state['gross_total_minor']) {
                        throw new \RuntimeException('ER057: amount/currency mismatch');
                    }
                    if ($state['status'] === 'paid') {
                        throw new \RuntimeException('ER055: already paid');
                    }
                    if ($state['status'] !== 'due') {
                        throw new \RuntimeException('ER056: no legal edge to paid');
                    }
                }

                $id = $state['next_payment_id']++;
                $state['payments'][$key] = ['id' => $id, 'status' => $status];

                if ($status === 'success') {
                    $state['status'] = 'paid';
                }

                return [['inv_record_payment' => $id]];
            },
        ]);
    }

    // -------------------------------------------------------------------------
    // resolvePayableIntent
    // -------------------------------------------------------------------------

    public function test_resolve_payable_intent_maps_payable_row_verbatim(): void
    {
        $state = $this->fakeInvoiceState();
        $this->installFakes($state);
        $adapter = new InvoiceSourceAdapter();

        $intent = $adapter->resolvePayableIntent('1', 'tenant-A', 'platform-A');

        $this->assertTrue($intent->isPayable);
        $this->assertSame('payable', $intent->reason);
        $this->assertSame(49900, $intent->amountMinorUnits);
        $this->assertSame('INR', $intent->currency);
        $this->assertSame('razorpay', $intent->gatewayCode);
        $this->assertSame('1', $intent->reference);
        $this->assertSame('https://pay.example.com/inv_1', $intent->checkoutEndpoint);
    }

    public function test_resolve_payable_intent_maps_already_paid_row_with_null_routing_fields(): void
    {
        $state = $this->fakeInvoiceState();
        $state['status'] = 'paid';
        $this->installFakes($state);
        $adapter = new InvoiceSourceAdapter();

        $intent = $adapter->resolvePayableIntent('1', 'tenant-A', 'platform-A');

        $this->assertFalse($intent->isPayable);
        $this->assertSame('already_paid', $intent->reason);
        $this->assertNull($intent->gatewayCode);
        $this->assertNull($intent->reference);
        $this->assertNull($intent->checkoutEndpoint);
    }

    // -------------------------------------------------------------------------
    // recordVerifiedPayment
    // -------------------------------------------------------------------------

    public function test_record_verified_payment_first_success_settles_invoice(): void
    {
        $state = $this->fakeInvoiceState();
        $this->installFakes($state);
        $adapter = new InvoiceSourceAdapter();

        $result = $adapter->recordVerifiedPayment(new RecordPaymentRequest(
            invoiceRef: '1',
            tenantId: 'tenant-A',
            platformCode: 'platform-A',
            gatewayCode: 'razorpay',
            gatewayTxnRef: 'pay_ABC',
            amountMinorUnits: 49900,
            currency: 'INR',
            status: 'success',
            capturedAt: new \DateTimeImmutable('2026-09-14T00:00:00+00:00'),
        ));

        $this->assertFalse($result->alreadyRecorded);
        $this->assertTrue($result->invoiceSettled);
        $this->assertNotSame('', $result->paymentRef);
    }

    public function test_record_verified_payment_replay_reports_already_recorded_and_stays_settled(): void
    {
        $state = $this->fakeInvoiceState();
        $this->installFakes($state);
        $adapter = new InvoiceSourceAdapter();

        $req = new RecordPaymentRequest(
            invoiceRef: '1',
            tenantId: 'tenant-A',
            platformCode: 'platform-A',
            gatewayCode: 'razorpay',
            gatewayTxnRef: 'pay_ABC',
            amountMinorUnits: 49900,
            currency: 'INR',
            status: 'success',
            capturedAt: new \DateTimeImmutable('2026-09-14T00:00:00+00:00'),
        );

        $first = $adapter->recordVerifiedPayment($req);
        $replay = $adapter->recordVerifiedPayment($req);

        $this->assertFalse($first->alreadyRecorded);
        $this->assertTrue($replay->alreadyRecorded, 'a webhook retry of the same gateway_txn_ref must be reported as a replay, never re-applied');
        $this->assertTrue($replay->invoiceSettled);
        $this->assertSame($first->paymentRef, $replay->paymentRef, 'a replay must return the SAME payment reference, never mint a new one');
    }

    public function test_record_verified_payment_passes_positional_params_in_sql_declaration_order(): void
    {
        $state = $this->fakeInvoiceState();
        $capturedParams = null;
        Database::fake([
            'inv_invoice_payability' => fn(array $params) => [[
                'invoice_id' => $params[0], 'is_payable' => true, 'status' => 'due', 'reason' => 'payable',
                'gross_total_minor' => 49900, 'currency' => 'INR', 'gateway_code' => 'razorpay',
                'checkout_endpoint' => 'https://pay.example.com/inv_1',
            ]],
            'inv_record_payment' => function (array $params) use (&$capturedParams) {
                $capturedParams = $params;

                return [['inv_record_payment' => 42]];
            },
        ]);
        $adapter = new InvoiceSourceAdapter(createdBy: 'test-suite');

        $adapter->recordVerifiedPayment(new RecordPaymentRequest(
            invoiceRef: '7',
            tenantId: 'tenant-A',
            platformCode: 'platform-A',
            gatewayCode: 'razorpay',
            gatewayTxnRef: 'pay_XYZ',
            amountMinorUnits: 49900,
            currency: 'INR',
            status: 'success',
            capturedAt: new \DateTimeImmutable('2026-09-14T12:00:00+00:00'),
        ));

        // Order MUST match inv_record_payment()'s SQL declaration order:
        // p_invoice_id, p_tenant_id, p_platform_code, p_gateway_code,
        // p_gateway_txn_ref, p_amount_minor, p_currency, p_status,
        // p_captured_at, p_created_by. (tenant_id/platform_code added
        // 2026-09-22, TENANT ISOLATION — see 035_04_inv_record_payment.pgsql.)
        $this->assertSame(7, $capturedParams[0]);
        $this->assertSame('tenant-A', $capturedParams[1]);
        $this->assertSame('platform-A', $capturedParams[2]);
        $this->assertSame('razorpay', $capturedParams[3]);
        $this->assertSame('pay_XYZ', $capturedParams[4]);
        $this->assertSame(49900, $capturedParams[5]);
        $this->assertSame('INR', $capturedParams[6]);
        $this->assertSame('success', $capturedParams[7]);
        $this->assertSame('2026-09-14T12:00:00+00:00', $capturedParams[8]);
        $this->assertSame('test-suite', $capturedParams[9]);
    }

    /**
     * Documented, surfaced limitation (see InvoiceSourceAdapter's
     * docblock): a 'failed' record's idempotent-replay cannot be detected
     * via the before/after invoice-status technique, because a failed
     * payment never transitions the invoice either way. alreadyRecorded is
     * always false for 'failed' — this test pins that documented behavior
     * so it can never silently change.
     */
    public function test_record_verified_payment_failed_status_never_settles_and_always_reports_not_already_recorded(): void
    {
        $state = $this->fakeInvoiceState();
        $this->installFakes($state);
        $adapter = new InvoiceSourceAdapter();

        $req = new RecordPaymentRequest(
            invoiceRef: '1',
            tenantId: 'tenant-A',
            platformCode: 'platform-A',
            gatewayCode: 'razorpay',
            gatewayTxnRef: 'pay_FAILED',
            amountMinorUnits: 49900,
            currency: 'INR',
            status: 'failed',
            capturedAt: new \DateTimeImmutable(),
        );

        $first = $adapter->recordVerifiedPayment($req);
        $replay = $adapter->recordVerifiedPayment($req);

        $this->assertFalse($first->invoiceSettled);
        $this->assertFalse($first->alreadyRecorded);
        $this->assertFalse($replay->invoiceSettled);
        $this->assertFalse($replay->alreadyRecorded, 'documented limitation: failed-status replays cannot be detected via invoice-status observation');
    }
}
