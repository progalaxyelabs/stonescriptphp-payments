<?php

declare(strict_types=1);

namespace StoneScriptPay\DTO;

/**
 * Request to create a payment order / checkout intent.
 *
 * Amount is ALWAYS set server-side — never trust a client-supplied amount.
 * amountMinorUnits is the amount in the smallest currency unit (paise for INR,
 * cents for USD, etc.).
 *
 * @package StoneScriptPay\DTO
 */
final class CreateOrderRequest
{
    /**
     * @param int    $amountMinorUnits  Server-set amount in minor units (e.g. paise). NEVER trust client.
     * @param string $currency          ISO 4217 currency code (e.g. 'INR').
     * @param string $receipt           Unique receipt / reference for this order (max 40 chars for Razorpay).
     * @param array  $notes             Key-value metadata embedded in the order (visible in Razorpay dashboard).
     */
    public function __construct(
        public readonly int $amountMinorUnits,
        public readonly string $currency,
        public readonly string $receipt,
        public readonly array $notes = [],
    ) {}
}
