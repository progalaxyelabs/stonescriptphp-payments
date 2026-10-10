<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Orders;

/**
 * An order as returned to the caller: everything the hosted checkout and the status poll need.
 * The same idempotency key always yields the same view (same order_ref, same gateway order).
 */
final class OrderView
{
    public function __construct(
        public readonly string $orderRef,
        public readonly string $gatewayCode,
        public readonly ?string $gatewayOrderId,
        public readonly int $amountMinorUnits,
        public readonly string $currency,
        public readonly string $mode,
        public readonly string $purpose,
        public readonly string $status,
        public readonly string $publishableKeyId,
        public readonly bool $isNew,
    ) {}

    /** @return array<string,mixed> */
    public function toArray(): array
    {
        return [
            'order_ref' => $this->orderRef,
            'gateway' => $this->gatewayCode,
            'gateway_order_id' => $this->gatewayOrderId,
            'amount_minor' => $this->amountMinorUnits,
            'currency' => $this->currency,
            'mode' => $this->mode,
            'purpose' => $this->purpose,
            'status' => $this->status,
            'key_id' => $this->publishableKeyId,
        ];
    }
}
