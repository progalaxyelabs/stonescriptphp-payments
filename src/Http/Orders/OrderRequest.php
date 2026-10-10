<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Orders;

/**
 * A request to create a payment order. All of it is SERVER-SIDE fact (the amount comes from the
 * platform's own price data, never from the browser); the library re-proves it (see
 * pay_order_create) rather than trusting it.
 *
 * Capture-first purposes (subscription_period, one_time_license, wallet_topup) need $catalogRef,
 * $seriesCode and $invoiceSpec; invoice_payment needs $invoiceId and nothing else.
 */
final class OrderRequest
{
    public const SUBSCRIPTION_PERIOD = 'subscription_period';
    public const ONE_TIME_LICENSE = 'one_time_license';
    public const WALLET_TOPUP = 'wallet_topup';
    public const INVOICE_PAYMENT = 'invoice_payment';

    /**
     * @param string $idempotencyKey Supplied by the caller; one key names one request.
     * @param ?array<string,mixed> $invoiceSpec  See _pay_order_spec_lines() for the shape.
     */
    public function __construct(
        public readonly string $tenantId,
        public readonly string $platformCode,
        public readonly string $idempotencyKey,
        public readonly string $gatewayCode,
        public readonly string $purpose,
        public readonly int $amountMinorUnits,
        public readonly string $currency,
        public readonly ?string $catalogRef = null,
        public readonly ?int $invoiceId = null,
        public readonly ?string $seriesCode = null,
        public readonly ?array $invoiceSpec = null,
        public readonly string $actor = 'orders',
    ) {}
}
