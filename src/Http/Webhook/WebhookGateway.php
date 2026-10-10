<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

use StoneScriptPay\Contracts\PaymentProvider;

/**
 * One gateway the ingress accepts webhooks for: its code (the URL segment and the pay_webhook_inbox.gateway_code) and
 * its driver. The signature header is the DRIVER's to declare (PaymentProvider::webhookSignatureHeader()), never a
 * default of the ingress.
 */
final class WebhookGateway
{
    public function __construct(
        public readonly string $code,
        public readonly PaymentProvider $provider,
    ) {}

    public function signatureHeader(): string
    {
        return strtolower($this->provider->webhookSignatureHeader());
    }
}
