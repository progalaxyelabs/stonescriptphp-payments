<?php

declare(strict_types=1);

namespace StoneScriptPay\DTO;

/**
 * Request to create a recurring subscription with the payment provider.
 *
 * @package StoneScriptPay\DTO
 */
final class CreateSubscriptionRequest
{
    /**
     * @param string   $planId        Provider plan ID (created in the provider dashboard or via API).
     * @param int      $totalCount    Number of billing cycles (0 = unlimited for Razorpay).
     * @param int      $quantity      Number of units (usually 1).
     * @param int|null $startAt       Unix timestamp when billing should start (null = immediately).
     * @param array    $customerNotify Whether to send provider-side notifications (1 = yes, 0 = no).
     * @param array    $notes         Key-value metadata.
     * @param string   $receipt       Optional receipt / reference.
     */
    public function __construct(
        public readonly string $planId,
        public readonly int $totalCount = 0,
        public readonly int $quantity = 1,
        public readonly ?int $startAt = null,
        public readonly int $customerNotify = 1,
        public readonly array $notes = [],
        public readonly string $receipt = '',
    ) {}
}
