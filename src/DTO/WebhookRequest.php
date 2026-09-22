<?php

declare(strict_types=1);

namespace StoneScriptPay\DTO;

/**
 * Inbound webhook from the payment provider.
 *
 * The driver verifies the signature/headers before parsing the payload.
 * Construct this from the raw HTTP request in the webhook route handler:
 *
 *   $req = new WebhookRequest(
 *       rawBody:   file_get_contents('php://input'),
 *       signature: $_SERVER['HTTP_X_RAZORPAY_SIGNATURE'] ?? '',
 *   );
 *
 * Single-header HMAC providers (Razorpay) only need $signature. Multi-header
 * verification-API providers (PayPal's verify-webhook-signature needs
 * transmission-id/time/cert-url/auth-algo/transmission-sig, not one HMAC
 * header) use the optional $headers map instead — added additively so
 * existing single-header callers/drivers are unaffected.
 *
 * @package StoneScriptPay\DTO
 */
final class WebhookRequest
{
    /**
     * @param string $rawBody    Raw request body exactly as received (used for HMAC verification).
     * @param string $signature  Provider signature header value (e.g. X-Razorpay-Signature). Unused
     *                           by multi-header providers — pass '' and use $headers instead.
     * @param array<string,string> $headers Full raw request headers (any casing), for drivers whose
     *                           verification needs more than one header (e.g. PayPal). Optional —
     *                           defaults to empty for providers that only need $signature.
     */
    public function __construct(
        public readonly string $rawBody,
        public readonly string $signature,
        public readonly array $headers = [],
    ) {}
}
