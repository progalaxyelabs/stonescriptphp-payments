<?php

declare(strict_types=1);

namespace StoneScriptPay\Drivers;

use StoneScriptPay\Contracts\PaymentProvider;
use StoneScriptPay\DTO\CreateOrderRequest;
use StoneScriptPay\DTO\CreateSubscriptionRequest;
use StoneScriptPay\DTO\OrderResult;
use StoneScriptPay\DTO\RefundRequest;
use StoneScriptPay\DTO\RefundResult;
use StoneScriptPay\DTO\SubscriptionResult;
use StoneScriptPay\DTO\VerificationResult;
use StoneScriptPay\DTO\VerifyRequest;
use StoneScriptPay\DTO\WebhookEvent;
use StoneScriptPay\DTO\WebhookRequest;
use StoneScriptPay\Exceptions\PaymentException;
use StoneScriptPay\Exceptions\SignatureVerificationException;
use StoneScriptPay\Exceptions\WebhookException;

/**
 * PayPal payment driver — PayPal Orders v2 REST API. Zero SDK, raw curl,
 * ported from a live bespoke client (create-order / capture-order /
 * webhook-signature-verification) that predates `stonescriptphp-pay` —
 * this is its natural home now that a shared payment contract exists.
 *
 * *** verifySignature() IS NOT SIDE-EFFECT-FREE FOR THIS DRIVER ***
 * Calling it actually CAPTURES the PayPal order (moves funds) — see the
 * Security section below for why that is the correct PayPal-shape
 * behaviour, not a shortcut. Idempotent against retries via a deterministic
 * `PayPal-Request-Id` header; an already-captured order is detected
 * (`ORDER_ALREADY_CAPTURED`) and treated as success rather than as a
 * signature failure. See captureOrderRaw()'s docblock for the full detail.
 *
 * Instantiation — credentials injected at runtime from app env:
 *
 *   $provider = new PaypalDriver(
 *       baseUrl:      $env->PAYPAL_BASE_URL,      // e.g. https://api-m.sandbox.paypal.com
 *       clientId:     $env->PAYPAL_CLIENT_ID,
 *       clientSecret: $env->PAYPAL_CLIENT_SECRET,
 *       webhookId:    $env->PAYPAL_WEBHOOK_ID,
 *   );
 *
 * Security:
 *   - createOrder() amount is always server-set via CreateOrderRequest.
 *   - handleWebhook() verifies via PayPal's verify-webhook-signature API
 *     (PayPal has no single-HMAC-header model like Razorpay — verification
 *     needs multiple transmission-* headers, carried via
 *     WebhookRequest::$headers).
 *   - verifySignature(): PayPal's Orders v2 flow has no separate
 *     "signature to check" step distinct from capture — the CAPTURE call
 *     itself (server-to-server, our credentials) is the authoritative
 *     confirmation that funds moved. This driver therefore performs the
 *     capture INSIDE verifySignature() and reports success only if the
 *     capture completed. $req->paymentId/$req->signature are unused
 *     (PayPal has neither before capture) — pass '' for both; only
 *     $req->orderId is read.
 *
 * MoR model: GATEWAY. The consuming application is the merchant of record
 * and is responsible for GST invoicing/remittance (PayPal-as-MoR is out of
 * scope for this driver).
 *
 * Not implemented: subscriptions. PayPal Subscriptions uses a distinct
 * Billing Plans/Agreements API that the ported client never touched —
 * createSubscription()/cancelSubscription()/getSubscription() throw
 * PaymentException rather than fake support. Only one-time order/capture
 * is live.
 *
 * @package StoneScriptPay\Drivers
 */
final class PaypalDriver implements PaymentProvider
{
    private readonly string $baseUrl;

    public function __construct(
        string $baseUrl,
        private readonly string $clientId,
        private readonly string $clientSecret,
        private readonly string $webhookId,
    ) {
        $this->baseUrl = rtrim($baseUrl, '/');
    }

    // -------------------------------------------------------------------------
    // Orders
    // -------------------------------------------------------------------------

    /**
     * @inheritdoc
     *
     * Creates a CAPTURE-intent PayPal order for a single purchase unit.
     * Amount is always server-set via $req->amountMinorUnits. The receipt
     * is echoed back as `custom_id` — the field PayPal's webhook resource
     * carries back to us, mapped to WebhookEvent::$invoiceRef.
     *
     * Note: minor-unit -> decimal-string conversion assumes a 2-decimal
     * currency (USD, EUR, INR, ...), matching the ported client's original
     * behavior. A 0-decimal currency (e.g. JPY) is NOT supported by this
     * conversion as written — a real gap surfaced, not silently handled.
     *
     * TENANT ISOLATION round-trip (added 2026-09-22): unlike Razorpay,
     * PayPal orders have no generic notes/metadata object — `custom_id` is
     * the ONLY free-form field PayPal echoes back verbatim on the capture
     * webhook. When the caller (CollectionOrchestrator::initiateCollection())
     * supplies tenant_id/platform_code via $req->notes, this driver encodes
     * them INTO custom_id as `receipt|tenantId|platformCode` (a real
     * provider constraint, not a design choice — there is nowhere else to
     * put them) and extractNormalisedFields() below splits it back apart.
     * custom_id has a real, hard 127-character PayPal limit; a combination
     * that would exceed it fails LOUD here (PaymentException) rather than
     * silently truncating and corrupting the tenant round-trip.
     */
    public function createOrder(CreateOrderRequest $req): OrderResult
    {
        // Compute+validate custom_id BEFORE the network round-trip (getAccessToken())
        // so a too-long tenant/receipt combination fails loud immediately,
        // without depending on network reachability, and never wastes an
        // access-token call on a request that cannot succeed.
        $customId = $req->receipt;
        $tenantId = $req->notes['tenant_id'] ?? null;
        $platformCode = $req->notes['platform_code'] ?? null;
        if ($tenantId !== null || $platformCode !== null) {
            // A literal '|' in any of the three parts would make the decode
            // side's explode($rawCustomId, limit: 3) split in the WRONG
            // place (e.g. a receipt containing '|' would bleed into
            // tenantId) — fail loud here rather than silently mis-parsing a
            // tenant identity on the way back in.
            foreach (['receipt' => $req->receipt, 'tenant_id' => $tenantId, 'platform_code' => $platformCode] as $label => $value) {
                if ($value !== null && str_contains((string) $value, '|')) {
                    throw new PaymentException(
                        "PayPal create-order: $label ('$value') contains a literal '|', which this driver "
                        . "uses as the custom_id delimiter for tenant_id/platform_code round-tripping — "
                        . 'refusing to encode an ambiguous custom_id.'
                    );
                }
            }
            $customId = $req->receipt . '|' . (string) $tenantId . '|' . (string) $platformCode;
            if (strlen($customId) > 127) {
                throw new PaymentException(
                    "PayPal create-order: encoded custom_id ('$customId') exceeds PayPal's 127-character "
                    . 'limit once receipt+tenant_id+platform_code are combined — cannot round-trip tenant '
                    . 'identity through this order without truncation/corruption.'
                );
            }
        }

        $token = $this->getAccessToken();

        $amount = number_format($req->amountMinorUnits / 100, 2, '.', '');

        $payload = [
            'intent' => 'CAPTURE',
            'purchase_units' => [[
                'custom_id' => $customId,
                'amount' => [
                    'currency_code' => $req->currency,
                    'value' => $amount,
                ],
            ]],
        ];
        if (!empty($req->notes)) {
            $payload['purchase_units'][0]['description'] = (string) ($req->notes['description'] ?? '');
        }

        [$code, $body] = $this->request(
            'POST',
            '/v2/checkout/orders',
            (string) json_encode($payload, JSON_THROW_ON_ERROR),
            ['Content-Type: application/json', "Authorization: Bearer $token"],
        );

        $json = json_decode($body, true);
        if ($code < 200 || $code >= 300 || !is_array($json) || empty($json['id'])) {
            throw new PaymentException("PayPal create-order failed (HTTP $code): $body");
        }

        return new OrderResult(
            orderId: (string) $json['id'],
            amountMinorUnits: $req->amountMinorUnits,
            currency: $req->currency,
            receipt: $req->receipt,
            publishableKeyId: $this->clientId,
            status: (string) ($json['status'] ?? ''),
            raw: $json,
        );
    }

    // -------------------------------------------------------------------------
    // Signature verification (== capture, for PayPal — see class docblock)
    // -------------------------------------------------------------------------

    /**
     * @inheritdoc
     *
     * IMPORTANT — this "verify" is NOT side-effect-free for PayPal: PayPal
     * has no client-returned HMAC to check like Razorpay, so the
     * server-to-server CAPTURE call is itself the authoritative
     * confirmation. Calling this method actually captures funds. Performs
     * the capture and reports success only if it completed (or was already
     * completed by an earlier, idempotent attempt — see captureOrderRaw()).
     * $req->paymentId and $req->signature are ignored.
     *
     * @throws SignatureVerificationException if the capture does not succeed.
     */
    public function verifySignature(VerifyRequest $req): VerificationResult
    {
        try {
            $capture = $this->captureOrderRaw($req->orderId);
        } catch (\Throwable $e) {
            throw new SignatureVerificationException('PayPal order capture: ' . $e->getMessage());
        }

        $status = (string) ($capture['status'] ?? '');
        if ($status !== 'COMPLETED') {
            throw new SignatureVerificationException("PayPal order capture status: $status");
        }

        $captureId = (string) ($capture['purchase_units'][0]['payments']['captures'][0]['id'] ?? '');

        return new VerificationResult(
            verified: true,
            paymentId: $captureId,
            orderId: $req->orderId,
        );
    }

    /**
     * Capture an approved PayPal order. Exposed for callers that need the
     * full decoded capture response (e.g. to re-verify amount/currency
     * before recording) rather than just verifySignature()'s summary.
     *
     * Idempotent: sends a deterministic `PayPal-Request-Id` (derived from
     * $orderId) so a client-side retry of the SAME order (network timeout,
     * process restart, ...) is recognised by PayPal as the same capture
     * attempt rather than a second, distinct one. PayPal's own idempotency
     * window is time-limited, not indefinite, so a retry outside that
     * window instead gets a 422 `ORDER_ALREADY_CAPTURED` error — WITHOUT
     * this handling, that looks identical to a genuine capture failure
     * (wrapped by verifySignature() into SignatureVerificationException, so
     * a successful payment would look like a failed signature). This
     * method treats `ORDER_ALREADY_CAPTURED` as success and fetches the
     * order's actual capture details instead of failing an already-settled
     * payment.
     *
     * @return array<string,mixed>
     * @throws PaymentException on any other failure.
     */
    public function captureOrderRaw(string $orderId): array
    {
        $token = $this->getAccessToken();
        $idempotencyKey = hash('sha256', 'capture:' . $orderId);

        [$code, $body] = $this->request(
            'POST',
            '/v2/checkout/orders/' . rawurlencode($orderId) . '/capture',
            '{}',
            [
                'Content-Type: application/json',
                "Authorization: Bearer $token",
                "PayPal-Request-Id: $idempotencyKey",
            ],
        );

        $json = json_decode($body, true);
        if ($code >= 200 && $code < 300 && is_array($json)) {
            return $json;
        }

        if ($code === 422 && $this->hasIssue($json, 'ORDER_ALREADY_CAPTURED')) {
            return $this->fetchOrder($orderId, $token);
        }

        throw new PaymentException("PayPal capture failed (HTTP $code): $body");
    }

    /**
     * @param mixed $decodedErrorBody
     */
    private function hasIssue(mixed $decodedErrorBody, string $issue): bool
    {
        if (!is_array($decodedErrorBody) || !is_array($decodedErrorBody['details'] ?? null)) {
            return false;
        }
        foreach ($decodedErrorBody['details'] as $detail) {
            if (is_array($detail) && ($detail['issue'] ?? '') === $issue) {
                return true;
            }
        }

        return false;
    }

    /**
     * GET the current order state — same `status` +
     * `purchase_units[].payments.captures[]` shape verifySignature() reads
     * off a normal capture response, used to recover the real capture
     * details after an ORDER_ALREADY_CAPTURED 422.
     *
     * @return array<string,mixed>
     */
    private function fetchOrder(string $orderId, string $token): array
    {
        [$code, $body] = $this->request(
            'GET',
            '/v2/checkout/orders/' . rawurlencode($orderId),
            '',
            ["Authorization: Bearer $token"],
        );

        $json = json_decode($body, true);
        if ($code < 200 || $code >= 300 || !is_array($json)) {
            throw new PaymentException("PayPal order fetch after ORDER_ALREADY_CAPTURED failed (HTTP $code): $body");
        }

        return $json;
    }

    // -------------------------------------------------------------------------
    // Webhooks
    // -------------------------------------------------------------------------

    /**
     * @inheritdoc
     *
     * Verifies via PayPal's verify-webhook-signature API (needs several
     * PAYPAL-TRANSMISSION-* headers, not one HMAC header — carried via
     * $req->headers, case-insensitive lookup). Only the terminal
     * PAYMENT.CAPTURE.COMPLETED event normalises to 'payment.captured';
     * every other event type normalises to 'unknown'.
     *
     * @throws SignatureVerificationException if verification fails.
     * @throws WebhookException if the payload is not valid JSON.
     */
    public function handleWebhook(WebhookRequest $req): WebhookEvent
    {
        if ($this->webhookId === '') {
            throw new WebhookException('webhookId is not configured');
        }

        $event = json_decode($req->rawBody, true);
        if (!is_array($event)) {
            throw new WebhookException('webhook body is not valid JSON');
        }

        if (!$this->verifyWebhookSignature($req->headers, $req->rawBody, $event)) {
            throw new SignatureVerificationException('webhook');
        }

        $providerEvent = (string) ($event['event_type'] ?? '');
        $type = $providerEvent === 'PAYMENT.CAPTURE.COMPLETED' ? 'payment.captured' : 'unknown';
        $resource = is_array($event['resource'] ?? null) ? $event['resource'] : [];

        [$invoiceRef, $gatewayTxnRef, $amountMinorUnits, $currency, $capturedAt, $tenantId, $platformCode] =
            $this->extractNormalisedFields($type, $resource);

        return new WebhookEvent(
            type: $type,
            providerEvent: $providerEvent,
            payload: $resource,
            raw: $event,
            invoiceRef: $invoiceRef,
            gatewayTxnRef: $gatewayTxnRef,
            amountMinorUnits: $amountMinorUnits,
            currency: $currency,
            capturedAt: $capturedAt,
            tenantId: $tenantId,
            platformCode: $platformCode,
        );
    }

    /**
     * Populate WebhookEvent's normalised fields from PayPal's native
     * `resource` shape — only for PAYMENT.CAPTURE.COMPLETED, same
     * discipline as RazorpayDriver.
     *
     * Note: same 2-decimal-currency assumption as createOrder() — a real,
     * surfaced limitation, not silently handled for 0-decimal currencies.
     *
     * tenant_id/platform_code (added 2026-09-22, TENANT ISOLATION): split
     * back out of the composite `receipt|tenantId|platformCode` custom_id
     * this driver's createOrder() encodes (see its docblock) — PayPal has
     * no separate metadata field to carry them in. A custom_id with no `|`
     * (an order created without tenant context, or by an older caller) is
     * treated as a bare invoiceRef with tenantId/platformCode left null —
     * CollectionOrchestrator::settleFromWebhook() then fails loud rather
     * than settling with an unenforceable tenant check.
     *
     * @return array{0:?string,1:?string,2:?int,3:?string,4:?\DateTimeImmutable,5:?string,6:?string}
     */
    private function extractNormalisedFields(string $type, array $resource): array
    {
        if ($type !== 'payment.captured') {
            return [null, null, null, null, null, null, null];
        }

        $rawCustomId = $resource['custom_id'] ?? null;
        $invoiceRef = $rawCustomId;
        $tenantId = null;
        $platformCode = null;
        if (is_string($rawCustomId) && str_contains($rawCustomId, '|')) {
            $parts = explode('|', $rawCustomId, 3);
            $invoiceRef = $parts[0];
            $tenantId = $parts[1] !== '' ? $parts[1] : null;
            $platformCode = $parts[2] !== '' ? $parts[2] : null;
        }
        $gatewayTxnRef = isset($resource['id']) ? (string) $resource['id'] : null;
        $amountValue = $resource['amount']['value'] ?? null;
        $amountMinorUnits = $amountValue !== null ? (int) round(((float) $amountValue) * 100) : null;
        $currency = isset($resource['amount']['currency_code']) ? (string) $resource['amount']['currency_code'] : null;
        $createTime = $resource['create_time'] ?? null;
        $capturedAt = null;
        if (is_string($createTime) && $createTime !== '') {
            $parsed = \DateTimeImmutable::createFromFormat(\DateTimeInterface::ATOM, $createTime)
                ?: \DateTimeImmutable::createFromFormat('Y-m-d\TH:i:s.u\Z', $createTime);
            $capturedAt = $parsed !== false ? $parsed : null;
        }

        return [
            $invoiceRef !== null ? (string) $invoiceRef : null,
            $gatewayTxnRef,
            $amountMinorUnits,
            $currency,
            $capturedAt,
            $tenantId,
            $platformCode,
        ];
    }

    /**
     * Verify a webhook notification signature via PayPal's
     * verify-webhook-signature API. An unverified POST must NEVER be
     * trusted.
     *
     * @param array<string,string> $headers Raw request headers, any casing.
     * @param array<mixed> $event Decoded webhook body.
     */
    private function verifyWebhookSignature(array $headers, string $rawBody, array $event): bool
    {
        $h = [];
        foreach ($headers as $k => $v) {
            $h[strtolower((string) $k)] = (string) $v;
        }

        try {
            $token = $this->getAccessToken();
        } catch (\Throwable $e) {
            return false;
        }

        $verifyPayload = json_encode([
            'transmission_id' => $h['paypal-transmission-id'] ?? '',
            'transmission_time' => $h['paypal-transmission-time'] ?? '',
            'cert_url' => $h['paypal-cert-url'] ?? '',
            'auth_algo' => $h['paypal-auth-algo'] ?? '',
            'transmission_sig' => $h['paypal-transmission-sig'] ?? '',
            'webhook_id' => $this->webhookId,
            'webhook_event' => $event,
        ]);

        [$code, $body] = $this->request(
            'POST',
            '/v1/notifications/verify-webhook-signature',
            (string) $verifyPayload,
            ['Content-Type: application/json', "Authorization: Bearer $token"],
        );

        $json = json_decode($body, true);

        return $code >= 200 && $code < 300
            && is_array($json)
            && ($json['verification_status'] ?? '') === 'SUCCESS';
    }

    // -------------------------------------------------------------------------
    // Subscriptions — NOT IMPLEMENTED (see class docblock)
    // -------------------------------------------------------------------------

    /**
     * @inheritdoc
     * @throws PaymentException always — PayPal Subscriptions (Billing
     *   Plans/Agreements) was never part of the ported live client.
     */
    public function createSubscription(CreateSubscriptionRequest $req): SubscriptionResult
    {
        throw new PaymentException(
            'PaypalDriver does not implement subscriptions — only one-time order/capture is ported '
            . 'from the live client. PayPal Subscriptions needs a separate Billing Plans/Agreements '
            . 'integration, not built here.'
        );
    }

    /** @inheritdoc */
    public function cancelSubscription(string $subscriptionId): SubscriptionResult
    {
        throw new PaymentException('PaypalDriver does not implement subscriptions — see createSubscription().');
    }

    /** @inheritdoc */
    public function getSubscription(string $subscriptionId): SubscriptionResult
    {
        throw new PaymentException('PaypalDriver does not implement subscriptions — see createSubscription().');
    }

    // -------------------------------------------------------------------------
    // Refunds
    // -------------------------------------------------------------------------

    /**
     * @inheritdoc
     *
     * Refunds a capture via PayPal's Payments API
     * (POST /v2/payments/captures/{id}/refund). $req->paymentId is the
     * CAPTURE id (not the order id) — same convention as
     * WebhookEvent::$gatewayTxnRef / verifySignature()'s returned paymentId.
     */
    public function refund(RefundRequest $req): RefundResult
    {
        $token = $this->getAccessToken();

        $payload = ['note_to_payer' => $req->reason];
        if ($req->amountMinorUnits !== null) {
            // Same 2-decimal-currency assumption as createOrder(); currency
            // is not carried on RefundRequest so it must come from $req->notes.
            $currency = (string) ($req->notes['currency'] ?? '');
            if ($currency === '') {
                throw new PaymentException('PaypalDriver::refund() partial refund requires notes[\'currency\'] to be set.');
            }
            $payload['amount'] = [
                'value' => number_format($req->amountMinorUnits / 100, 2, '.', ''),
                'currency_code' => $currency,
            ];
        }

        [$code, $body] = $this->request(
            'POST',
            '/v2/payments/captures/' . rawurlencode($req->paymentId) . '/refund',
            (string) json_encode($payload, JSON_THROW_ON_ERROR),
            ['Content-Type: application/json', "Authorization: Bearer $token"],
        );

        $json = json_decode($body, true);
        if ($code < 200 || $code >= 300 || !is_array($json) || empty($json['id'])) {
            throw new PaymentException("PayPal refund failed (HTTP $code): $body");
        }

        $amountValue = $json['amount']['value'] ?? null;

        return new RefundResult(
            refundId: (string) $json['id'],
            paymentId: $req->paymentId,
            amountMinorUnits: $amountValue !== null ? (int) round(((float) $amountValue) * 100) : ($req->amountMinorUnits ?? 0),
            status: (string) ($json['status'] ?? ''),
            createdAt: isset($json['create_time']) ? (new \DateTimeImmutable($json['create_time']))->getTimestamp() : time(),
            raw: $json,
        );
    }

    // -------------------------------------------------------------------------
    // Settlement model
    // -------------------------------------------------------------------------

    /** @inheritdoc */
    public function settlementModel(): string
    {
        return 'gateway';
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /**
     * OAuth2 client_credentials access token.
     *
     * @throws PaymentException on failure.
     */
    private function getAccessToken(): string
    {
        [$code, $body] = $this->request(
            'POST',
            '/v1/oauth2/token',
            'grant_type=client_credentials',
            ['Content-Type: application/x-www-form-urlencoded'],
            $this->clientId . ':' . $this->clientSecret,
        );

        $json = json_decode($body, true);
        if ($code < 200 || $code >= 300 || !is_array($json) || empty($json['access_token'])) {
            throw new PaymentException("PayPal token request failed (HTTP $code)");
        }

        return (string) $json['access_token'];
    }

    /**
     * Low-level curl. Returns [httpCode, responseBody].
     *
     * @param array<int,string> $headers
     * @return array{0:int,1:string}
     */
    private function request(string $method, string $path, string $body, array $headers, ?string $basicAuth = null): array
    {
        $ch = curl_init($this->baseUrl . $path);
        $opts = [
            CURLOPT_CUSTOMREQUEST => $method,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HTTPHEADER => $headers,
            CURLOPT_TIMEOUT => 20,
        ];
        // Only attach a body for methods that carry one — a GET (e.g.
        // fetchOrder()) must not send CURLOPT_POSTFIELDS.
        if ($body !== '') {
            $opts[CURLOPT_POSTFIELDS] = $body;
        }
        if ($basicAuth !== null) {
            $opts[CURLOPT_USERPWD] = $basicAuth;
        }
        curl_setopt_array($ch, $opts);

        $response = curl_exec($ch);
        $httpCode = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $err = curl_error($ch);
        curl_close($ch);

        if ($response === false) {
            throw new PaymentException("PayPal request transport error: $err");
        }

        return [$httpCode, (string) $response];
    }
}
