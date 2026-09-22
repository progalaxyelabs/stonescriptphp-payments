<?php

declare(strict_types=1);

namespace StoneScriptPay\DTO;

/**
 * Result returned by PaymentProvider::refund().
 *
 * @package StoneScriptPay\DTO
 */
final class RefundResult
{
    /**
     * @param string $refundId         Provider-assigned refund ID.
     * @param string $paymentId        Original payment ID that was refunded.
     * @param int    $amountMinorUnits  Amount refunded in minor units.
     * @param string $status           Provider status (e.g. "processed", "pending").
     * @param int    $createdAt        Unix timestamp of refund creation.
     * @param array  $raw              Raw provider response.
     */
    public function __construct(
        public readonly string $refundId,
        public readonly string $paymentId,
        public readonly int $amountMinorUnits,
        public readonly string $status,
        public readonly int $createdAt,
        public readonly array $raw = [],
    ) {}

    public function isProcessed(): bool
    {
        return $this->status === 'processed';
    }
}
