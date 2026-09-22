<?php

declare(strict_types=1);

namespace StoneScriptPHP\Invoice\Php;

use StoneScriptPHP\Billing\Contracts\InvoiceSource;
use StoneScriptPHP\Billing\Contracts\PayableIntent;
use StoneScriptPHP\Billing\Contracts\RecordPaymentRequest;
use StoneScriptPHP\Billing\Contracts\RecordPaymentResult;
use StoneScriptPHP\Database;

/**
 * The SOLE PHP file in `stonescriptphp-invoice` — a thin transport shim
 * implementing `StoneScriptPHP\Billing\Contracts\InvoiceSource` by calling
 * this package's `inv_*` SQL functions via `Database::fn()`. Pure
 * marshalling: paise/cents ints in and out, `reason`/`status` strings
 * passed through verbatim, NO amount/tax/routing/idempotency logic — every
 * decision this class reports was already made by the SQL function it
 * called (see `035_invoice_functions.pgsql`). This is the framework
 * ecosystem's "PHP is web-only/transport" law applied to this package's
 * one PHP file.
 *
 * `invoiceRef` is this package's `inv_invoices.id` (a `BIGINT`) rendered
 * as a decimal string, matching `InvoiceSource`'s "opaque string" contract
 * — callers never need to know it's numeric.
 *
 * Requires `progalaxyelabs/stonescriptphp` (for `Database::fn()` and the
 * `InvoiceSource` contract it implements) ONLY when this class is actually
 * instantiated — a project using `stonescriptphp-invoice` purely for its
 * SQL (issue invoices, run the CRM chase, mark paid manually) never
 * autoloads this file and never needs the framework installed. See this
 * package's composer.json — framework is `require-dev` + `suggest`, not a
 * hard `require`.
 */
final class InvoiceSourceAdapter implements InvoiceSource
{
    /**
     * @param string $createdBy Attribution string recorded on
     *   `inv_payments.created_by` — pass something identifying the calling
     *   system/service (e.g. 'webhook:razorpay', 'central-pay-service').
     */
    public function __construct(
        private readonly string $createdBy = 'invoice_source_adapter',
    ) {
    }

    /**
     * @inheritdoc
     *
     * Marshals `inv_invoice_payability(p_invoice_id, p_tenant_id,
     * p_platform_code)`'s result row into a `PayableIntent` — the SQL
     * function alone decides is_payable/reason/amount/currency/gateway/
     * checkout target; this method computes none of it. $tenantId/
     * $platformCode are passed straight through so the SQL function's
     * ER067 tenant-ownership check applies (see that function's docblock,
     * 035_05) — this adapter enforces nothing itself, it only carries the
     * caller's identity to the layer that does.
     */
    public function resolvePayableIntent(string $invoiceRef, string $tenantId, string $platformCode): PayableIntent
    {
        $row = $this->fetchPayability($invoiceRef, $tenantId, $platformCode);

        return new PayableIntent(
            isPayable: (bool) $row['is_payable'],
            reason: (string) $row['reason'],
            amountMinorUnits: (int) $row['gross_total_minor'],
            currency: (string) $row['currency'],
            gatewayCode: $row['gateway_code'] !== null ? (string) $row['gateway_code'] : null,
            reference: $row['is_payable'] ? (string) $row['invoice_id'] : null,
            checkoutEndpoint: $row['checkout_endpoint'] !== null ? (string) $row['checkout_endpoint'] : null,
        );
    }

    /**
     * @inheritdoc
     *
     * Calls `inv_record_payment()` — the ONE atomic call that idempotently
     * records the payment AND (on a genuine new success) fires the single
     * `due->paid` transition. This method never re-implements idempotency
     * or the amount/currency-match guard; both live in the SQL function
     * (a replay of the same `gateway_txn_ref` returns the existing payment
     * id; a mismatched amount/currency raises ER057).
     *
     * `alreadyRecorded` detection: `inv_record_payment` itself returns only
     * the payment id either way (new insert or idempotent replay), with no
     * separate "was this new?" flag exposed at the SQL layer (this
     * package's public contract, unchanged by this adapter). This method
     * infers replay PURELY from the invoice's own before/after payability
     * status — observation, not a decision:
     *
     *   - For a 'success' record: if the invoice was ALREADY 'paid' before
     *     this call and the call did not raise (`inv_record_payment` would
     *     raise ER055 for a genuinely NEW success against an already-paid
     *     invoice), the only way execution reaches here is that this was
     *     an idempotent replay — a logical proof, not a guess.
     *   - For a 'failed' record: the invoice's status never transitions
     *     either way (success or replay), so this before/after technique
     *     CANNOT distinguish a replay from a fresh failed record.
     *     `alreadyRecorded` is reported as `false` for 'failed' regardless
     *     — a real, surfaced limitation (not silently papered over) that
     *     does not affect settlement correctness (`inv_record_payment`'s
     *     own gateway_txn_ref uniqueness still prevents any duplicate
     *     'failed' row from being inserted; only this adapter's
     *     `alreadyRecorded` REPORTING is imprecise for that one case).
     */
    public function recordVerifiedPayment(RecordPaymentRequest $req): RecordPaymentResult
    {
        $beforeRow = $this->fetchPayability($req->invoiceRef, $req->tenantId, $req->platformCode);
        $wasAlreadyPaid = ($beforeRow['status'] ?? null) === 'paid';

        // p_tenant_id/p_platform_code (2nd/3rd positional params, matching
        // inv_record_payment's SQL declaration order, 035_04) so ER067's
        // tenant-ownership check applies here exactly as it does to the
        // payability read above — this is the ONE call that can mutate an
        // invoice into 'paid', so it is the highest-value place this
        // adapter must not skip the check.
        $rows = Database::fn('inv_record_payment', [
            (int) $req->invoiceRef,
            $req->tenantId,
            $req->platformCode,
            $req->gatewayCode,
            $req->gatewayTxnRef,
            $req->amountMinorUnits,
            $req->currency,
            $req->status,
            $req->capturedAt->format(\DateTimeInterface::ATOM),
            $this->createdBy,
        ]);
        $paymentRef = (string) ($rows[0]['inv_record_payment'] ?? '');

        $afterRow = $this->fetchPayability($req->invoiceRef, $req->tenantId, $req->platformCode);
        $isPaidNow = ($afterRow['status'] ?? null) === 'paid';

        return new RecordPaymentResult(
            paymentRef: $paymentRef,
            alreadyRecorded: $req->status === 'success' && $wasAlreadyPaid && $isPaidNow,
            invoiceSettled: $isPaidNow,
        );
    }

    /**
     * @return array<string, mixed> The single result row from
     *   `inv_invoice_payability()`.
     */
    private function fetchPayability(string $invoiceRef, string $tenantId, string $platformCode): array
    {
        $rows = Database::fn('inv_invoice_payability', [(int) $invoiceRef, $tenantId, $platformCode]);

        return $rows[0] ?? throw new \RuntimeException(
            "InvoiceSourceAdapter: inv_invoice_payability returned no row for invoice_id '$invoiceRef'."
        );
    }
}
