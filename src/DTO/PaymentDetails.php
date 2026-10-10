<?php

declare(strict_types=1);

namespace StoneScriptPay\DTO;

/**
 * A payment as the GATEWAY reports it right now (PaymentProvider::fetchPayment()), normalised.
 *
 * Used to confirm a payment independently of any message we were sent (an operator applying a
 * payment id by hand, a reconciliation job): trust the gateway's own record, not a pasted id.
 *
 * Canonical status values: 'captured' (money taken and settled to us), 'authorized' (held, not
 * captured), 'failed', 'refunded', 'created' (not yet attempted/paid), 'unknown'.
 */
final class PaymentDetails
{
    /**
     * @param string $paymentId       The gateway's payment / capture id.
     * @param string $status         Normalised status (see class docblock).
     * @param int    $amountMinorUnits Amount in minor units (paise/cents).
     * @param string $currency       ISO 4217.
     * @param ?string $gatewayOrderId The gateway order this payment belongs to (Razorpay order_id; PayPal order id), if reported.
     * @param ?\DateTimeImmutable $capturedAt The gateway's own capture time, if reported.
     * @param int $amountRefundedMinorUnits Amount already refunded (a partly refunded payment still reports 'captured').
     * @param bool $capturedAtIsEstimate True when $capturedAt is a proxy (the payment's creation time), not a reported capture time.
     * @param array<string,mixed> $notes The merchant notes / custom reference echoed back (Razorpay notes; PayPal custom_id under 'custom_id').
     * @param array<string,mixed> $raw  The gateway's full response, for audit.
     */
    public function __construct(
        public readonly string $paymentId,
        public readonly string $status,
        public readonly int $amountMinorUnits,
        public readonly string $currency,
        public readonly ?string $gatewayOrderId = null,
        public readonly ?\DateTimeImmutable $capturedAt = null,
        public readonly array $notes = [],
        public readonly array $raw = [],
        public readonly int $amountRefundedMinorUnits = 0,
        public readonly bool $capturedAtIsEstimate = false,
    ) {}

    public function isPartlyRefunded(): bool
    {
        return $this->amountRefundedMinorUnits > 0;
    }

    public function isCaptured(): bool
    {
        return $this->status === 'captured';
    }
}
