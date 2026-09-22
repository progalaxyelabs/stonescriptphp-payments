<?php

declare(strict_types=1);

namespace StoneScriptPay\DTO;

/**
 * Result returned by subscription lifecycle methods on PaymentProvider.
 *
 * @package StoneScriptPay\DTO
 */
final class SubscriptionResult
{
    /**
     * @param string      $subscriptionId  Provider-assigned subscription ID.
     * @param string      $status          Provider status string (e.g. "created", "active", "cancelled", "halted").
     * @param string|null $planId          Provider plan ID this subscription is on.
     * @param int|null    $currentStart    Unix timestamp of current billing period start.
     * @param int|null    $currentEnd      Unix timestamp of current billing period end.
     * @param int|null    $endAt           Unix timestamp of subscription end (null if ongoing).
     * @param int         $paidCount       Number of billing cycles completed.
     * @param int         $remainingCount  Number of billing cycles remaining (0 = unlimited).
     * @param array       $raw             Raw provider response.
     */
    public function __construct(
        public readonly string $subscriptionId,
        public readonly string $status,
        public readonly ?string $planId = null,
        public readonly ?int $currentStart = null,
        public readonly ?int $currentEnd = null,
        public readonly ?int $endAt = null,
        public readonly int $paidCount = 0,
        public readonly int $remainingCount = 0,
        public readonly array $raw = [],
    ) {}

    public function isActive(): bool
    {
        return in_array($this->status, ['active', 'authenticated'], true);
    }

    public function isCancelled(): bool
    {
        return $this->status === 'cancelled';
    }
}
