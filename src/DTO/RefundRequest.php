<?php

declare(strict_types=1);

namespace StoneScriptPay\DTO;

/**
 * Request to refund a payment (full or partial).
 *
 * @package StoneScriptPay\DTO
 */
final class RefundRequest
{
    /**
     * @param string   $paymentId        Provider payment ID to refund.
     * @param int|null $amountMinorUnits  Amount to refund in minor units. Null = full refund.
     * @param string   $reason            Reason for the refund (customer_request, fraud, duplicate, other).
     * @param array    $notes             Key-value metadata.
     */
    public function __construct(
        public readonly string $paymentId,
        public readonly ?int $amountMinorUnits = null,
        public readonly string $reason = 'customer_request',
        public readonly array $notes = [],
    ) {}
}
