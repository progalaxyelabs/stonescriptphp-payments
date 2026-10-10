<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Orders;

use StoneScriptPay\Http\Webhook\SqlFunctionCaller;

/**
 * The single PHP entry to pay_apply_capture. The webhook processor and the operator path both go
 * through here, so there is exactly one way a capture takes effect. Pure marshalling: every
 * decision (mismatch, duplicate, unattributed, atomic rollback) is made in SQL.
 *
 * Throws when SQL refuses the capture (a mismatch or a duplicate payment for a paid order): the
 * caller treats that as a failure to be alerted on, never as success.
 */
final class CaptureApplier
{
    public function __construct(private readonly SqlFunctionCaller $db) {}

    public function apply(CapturePayment $c): CaptureOutcome
    {
        $rows = $this->db->call('pay_apply_capture', [
            $c->gatewayCode,
            $c->gatewayTxnRef,
            $c->orderRef,
            $c->tenantId,
            $c->platformCode,
            $c->amountMinorUnits,
            $c->currency,
            $c->mode,
            $c->capturedAt->format(\DateTimeInterface::ATOM),
            $c->source,
            $c->rawJson,
            $c->issuedAt?->format(\DateTimeInterface::ATOM),
        ]);
        $r = $rows[0] ?? throw new \RuntimeException('pay_apply_capture returned no row: the capture was NOT confirmed applied.');

        return new CaptureOutcome(
            outcome: (string) $r['o_outcome'],
            orderRef: isset($r['o_order_ref']) ? (string) $r['o_order_ref'] : null,
            purpose: isset($r['o_purpose']) ? (string) $r['o_purpose'] : null,
            invoiceId: isset($r['o_invoice_id']) ? (int) $r['o_invoice_id'] : null,
            paymentId: isset($r['o_payment_id']) ? (int) $r['o_payment_id'] : null,
            detail: isset($r['o_detail']) ? (string) $r['o_detail'] : null,
        );
    }
}
