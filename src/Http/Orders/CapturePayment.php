<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Orders;

/**
 * One gateway capture to be applied. Built from a verified webhook event or, after the gateway
 * has confirmed it, from an operator's request. $tenantId / $platformCode are the identity the
 * gateway echoed back (nullable); when present, SQL requires them to equal the order's.
 *
 * $rawJson must already be the allow-listed, non-personal form (RawPayloadAllowlist). $issuedAt is the moment the invoice is
 * issued (null = now): the invoice is numbered into the financial year of THAT moment, not of $capturedAt.
 */
final class CapturePayment
{
    public function __construct(
        public readonly string $gatewayCode,
        public readonly string $gatewayTxnRef,
        public readonly ?string $orderRef,
        public readonly ?string $tenantId,
        public readonly ?string $platformCode,
        public readonly int $amountMinorUnits,
        public readonly string $currency,
        public readonly string $mode,
        public readonly \DateTimeImmutable $capturedAt,
        public readonly string $source,
        public readonly ?string $rawJson = null,
        public readonly ?\DateTimeImmutable $issuedAt = null,
    ) {}
}
