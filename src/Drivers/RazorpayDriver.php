<?php

declare(strict_types=1);

namespace StoneScriptPay\Drivers;

use Razorpay\Api\Api as RazorpayApi;
use Razorpay\Api\Errors\SignatureVerificationError;
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
 * Razorpay payment driver.
 *
 * Implements PaymentProvider using the razorpay/razorpay SDK.
 *
 * Instantiation — credentials are injected at runtime from app env:
 *
 *   $provider = new RazorpayDriver(
 *       keyId:         $env->RAZORPAY_KEY_ID,
 *       keySecret:     $env->RAZORPAY_KEY_SECRET,
 *       webhookSecret: $env->RAZORPAY_WEBHOOK_SECRET,
 *   );
 *
 * Security:
 *   - createOrder() amount is always server-set via CreateOrderRequest.
 *   - verifySignature() uses HMAC-SHA256 over "{orderId}|{paymentId}" with keySecret.
 *   - handleWebhook() uses HMAC-SHA256 over raw body with webhookSecret.
 *
 * MoR model: GATEWAY. The consuming application is the merchant of record and is
 * responsible for GST invoicing and remittance.
 *
 * @package StoneScriptPay\Drivers
 */
final class RazorpayDriver implements PaymentProvider
{
    private ?RazorpayApi $api = null;

    /**
     * @param string $keyId         Razorpay Key ID (publishable — safe to send to frontend).
     *                               May be left '' for a driver instance that ONLY ever calls
     *                               handleWebhook() (webhook verification needs $webhookSecret
     *                               only, never the API keys) — any method that actually calls
     *                               the Razorpay API throws PaymentException lazily if empty.
     * @param string $keySecret     Razorpay Key Secret (NEVER send to frontend — server only).
     * @param string $webhookSecret Razorpay Webhook Secret (NEVER send to frontend — server only).
     */
    public function __construct(
        private readonly string $keyId,
        private readonly string $keySecret,
        private readonly string $webhookSecret,
    ) {
    }

    /**
     * Lazily builds (and caches) the Razorpay API client. Deferred from the
     * constructor so a driver instance built for webhook-only use (e.g. a
     * consuming app's subscription glue, which historically only ever held a
     * webhook secret) doesn't need real API keys just to verify signatures.
     *
     * @throws PaymentException if keyId/keySecret are missing when an
     *   actual API call is attempted.
     */
    private function getApi(): RazorpayApi
    {
        if ($this->api === null) {
            if (empty($this->keyId) || empty($this->keySecret)) {
                throw new PaymentException('Razorpay keyId and keySecret are required for this operation');
            }
            $this->api = new RazorpayApi($this->keyId, $this->keySecret);
        }

        return $this->api;
    }

    // -------------------------------------------------------------------------
    // Orders
    // -------------------------------------------------------------------------

    /**
     * @inheritdoc
     *
     * Creates a Razorpay order. Amount is always server-set via $req->amountMinorUnits
     * (paise for INR). Returns an OrderResult with the order_id and publishable key_id
     * for the frontend hosted checkout.
     */
    public function createOrder(CreateOrderRequest $req): OrderResult
    {
        try {
            $payload = [
                'amount'   => $req->amountMinorUnits,
                'currency' => $req->currency,
                'receipt'  => substr($req->receipt, 0, 40), // Razorpay max 40 chars
            ];

            if (!empty($req->notes)) {
                $payload['notes'] = $req->notes;
            }

            $order = $this->getApi()->order->create($payload);

            return new OrderResult(
                orderId:          $order->id,
                amountMinorUnits: (int) $order->amount,
                currency:         $order->currency,
                receipt:          $order->receipt,
                publishableKeyId: $this->keyId,
                status:           $order->status,
                raw:              $this->toArray($order),
            );
        } catch (\Exception $e) {
            throw new PaymentException(
                'Razorpay order creation failed: ' . $e->getMessage(),
                0,
                $e,
            );
        }
    }

    // -------------------------------------------------------------------------
    // Signature verification
    // -------------------------------------------------------------------------

    /**
     * @inheritdoc
     *
     * Verifies the HMAC-SHA256 signature returned by Razorpay hosted checkout.
     *
     * Razorpay signature formula:
     *   HMAC-SHA256("{orderId}|{paymentId}", keySecret)
     *
     * @throws SignatureVerificationException on mismatch.
     */
    public function verifySignature(VerifyRequest $req): VerificationResult
    {
        try {
            $this->getApi()->utility->verifyPaymentSignature([
                'razorpay_order_id'   => $req->orderId,
                'razorpay_payment_id' => $req->paymentId,
                'razorpay_signature'  => $req->signature,
            ]);
        } catch (SignatureVerificationError $e) {
            throw new SignatureVerificationException('payment response');
        } catch (\Exception $e) {
            throw new SignatureVerificationException('payment response');
        }

        return new VerificationResult(
            verified:  true,
            paymentId: $req->paymentId,
            orderId:   $req->orderId,
        );
    }

    // -------------------------------------------------------------------------
    // Webhooks
    // -------------------------------------------------------------------------

    /**
     * @inheritdoc
     *
     * Verifies the X-Razorpay-Signature header against the raw request body using
     * the webhook secret (HMAC-SHA256), then parses the event into a WebhookEvent.
     *
     * Webhook signature formula:
     *   HMAC-SHA256(rawBody, webhookSecret)
     *
     * @throws SignatureVerificationException if the signature header is missing or invalid.
     * @throws WebhookException if the payload is not valid JSON.
     */
    public function handleWebhook(WebhookRequest $req): WebhookEvent
    {
        // Guard: webhook secret must be configured
        if (empty($this->webhookSecret)) {
            throw new WebhookException('webhookSecret is not configured');
        }

        // Guard: signature header must be present
        if (empty($req->signature)) {
            throw new SignatureVerificationException('webhook (missing X-Razorpay-Signature header)');
        }

        // Verify HMAC-SHA256 over raw body
        $expected = hash_hmac('sha256', $req->rawBody, $this->webhookSecret);
        if (!hash_equals($expected, $req->signature)) {
            throw new SignatureVerificationException('webhook');
        }

        // Parse payload
        $payload = json_decode($req->rawBody, true);
        if (!is_array($payload)) {
            throw new WebhookException('webhook body is not valid JSON');
        }

        $providerEvent = $payload['event'] ?? '';
        $type = $this->normaliseEventType($providerEvent);
        $entityPayload = $payload['payload'] ?? [];

        [$invoiceRef, $gatewayTxnRef, $amountMinorUnits, $currency, $capturedAt, $tenantId, $platformCode] =
            $this->extractNormalisedFields($type, $entityPayload);

        return new WebhookEvent(
            type:             $type,
            providerEvent:    $providerEvent,
            payload:          $entityPayload,
            raw:              $payload,
            invoiceRef:       $invoiceRef,
            gatewayTxnRef:    $gatewayTxnRef,
            amountMinorUnits: $amountMinorUnits,
            currency:         $currency,
            capturedAt:       $capturedAt,
            tenantId:         $tenantId,
            platformCode:     $platformCode,
        );
    }

    /**
     * Populate WebhookEvent's normalised, provider-agnostic fields from
     * Razorpay's native payload.entity shape — ONLY for settlement event
     * types this driver can unambiguously map (payment.captured). Other
     * event types return all-null; consumers reading only $payload/$raw
     * are unaffected either way.
     *
     * @return array{0:?string,1:?string,2:?int,3:?string,4:?\DateTimeImmutable,5:?string,6:?string}
     */
    private function extractNormalisedFields(string $type, array $entityPayload): array
    {
        if ($type !== 'payment.captured') {
            return [null, null, null, null, null, null, null];
        }

        $entity = $entityPayload['payment']['entity'] ?? null;
        if (!is_array($entity)) {
            return [null, null, null, null, null, null, null];
        }

        $invoiceRef = $entity['notes']['invoice_ref'] ?? null;
        // tenant_id/platform_code (added 2026-09-22, TENANT ISOLATION):
        // embedded into the order's notes by CollectionOrchestrator::
        // initiateCollection() at checkout time and echoed back verbatim by
        // Razorpay on the verified webhook payload — see WebhookEvent's and
        // RecordPaymentRequest's docblocks for why this round-trip exists.
        $tenantId = $entity['notes']['tenant_id'] ?? null;
        $platformCode = $entity['notes']['platform_code'] ?? null;
        $gatewayTxnRef = isset($entity['id']) ? (string) $entity['id'] : null;
        $amountMinorUnits = isset($entity['amount']) ? (int) $entity['amount'] : null;
        $currency = isset($entity['currency']) ? (string) $entity['currency'] : null;
        // Razorpay's payment entity carries `created_at` (unix seconds); there is
        // no separate machine-readable capture timestamp on the webhook payload,
        // so this is used as the capture time proxy.
        $capturedAt = isset($entity['created_at'])
            ? (new \DateTimeImmutable())->setTimestamp((int) $entity['created_at'])
            : null;

        return [
            $invoiceRef !== null ? (string) $invoiceRef : null,
            $gatewayTxnRef,
            $amountMinorUnits,
            $currency,
            $capturedAt,
            $tenantId !== null ? (string) $tenantId : null,
            $platformCode !== null ? (string) $platformCode : null,
        ];
    }

    /**
     * Normalise Razorpay event strings to the canonical WebhookEvent types.
     */
    private function normaliseEventType(string $providerEvent): string
    {
        return match ($providerEvent) {
            'payment.captured'        => 'payment.captured',
            'payment.failed'          => 'payment.failed',
            'subscription.activated'  => 'subscription.activated',
            'subscription.charged'    => 'subscription.charged',
            'subscription.completed'  => 'subscription.completed',
            'subscription.cancelled'  => 'subscription.cancelled',
            'subscription.halted'     => 'subscription.halted',
            'refund.created'          => 'refund.created',
            'refund.processed'        => 'refund.processed',
            default                   => 'unknown',
        };
    }

    // -------------------------------------------------------------------------
    // Subscriptions
    // -------------------------------------------------------------------------

    /**
     * @inheritdoc
     *
     * Creates a Razorpay subscription against an existing plan (created in the
     * Razorpay dashboard or via the Plans API).
     */
    public function createSubscription(CreateSubscriptionRequest $req): SubscriptionResult
    {
        try {
            $payload = [
                'plan_id'         => $req->planId,
                'total_count'     => $req->totalCount,
                'quantity'        => $req->quantity,
                'customer_notify' => $req->customerNotify,
            ];

            if ($req->startAt !== null) {
                $payload['start_at'] = $req->startAt;
            }
            if (!empty($req->notes)) {
                $payload['notes'] = $req->notes;
            }

            $sub = $this->getApi()->subscription->create($payload);

            return $this->mapSubscription($sub);
        } catch (\Exception $e) {
            throw new PaymentException(
                'Razorpay subscription creation failed: ' . $e->getMessage(),
                0,
                $e,
            );
        }
    }

    /**
     * @inheritdoc
     *
     * Cancels the subscription at the end of the current billing period
     * (cancel_at_cycle_end=1). Pass 0 to cancel immediately.
     */
    public function cancelSubscription(string $subscriptionId): SubscriptionResult
    {
        try {
            $sub = $this->getApi()->subscription->fetch($subscriptionId)->cancel([
                'cancel_at_cycle_end' => 1,
            ]);

            return $this->mapSubscription($sub);
        } catch (\Exception $e) {
            throw new PaymentException(
                'Razorpay subscription cancellation failed: ' . $e->getMessage(),
                0,
                $e,
            );
        }
    }

    /**
     * @inheritdoc
     */
    public function getSubscription(string $subscriptionId): SubscriptionResult
    {
        try {
            $sub = $this->getApi()->subscription->fetch($subscriptionId);

            return $this->mapSubscription($sub);
        } catch (\Exception $e) {
            throw new PaymentException(
                'Razorpay subscription fetch failed: ' . $e->getMessage(),
                0,
                $e,
            );
        }
    }

    /**
     * Map a Razorpay subscription object to SubscriptionResult.
     */
    private function mapSubscription(object $sub): SubscriptionResult
    {
        $raw = $this->toArray($sub);

        return new SubscriptionResult(
            subscriptionId: $sub->id,
            status:         $sub->status,
            planId:         $sub->plan_id ?? null,
            currentStart:   isset($sub->current_start)  ? (int) $sub->current_start  : null,
            currentEnd:     isset($sub->current_end)    ? (int) $sub->current_end    : null,
            endAt:          isset($sub->end_at)         ? (int) $sub->end_at         : null,
            paidCount:      (int) ($sub->paid_count     ?? 0),
            remainingCount: (int) ($sub->remaining_count ?? 0),
            raw:            $raw,
        );
    }

    // -------------------------------------------------------------------------
    // Refunds
    // -------------------------------------------------------------------------

    /**
     * @inheritdoc
     *
     * Issues a full or partial refund. amountMinorUnits null = full refund.
     */
    public function refund(RefundRequest $req): RefundResult
    {
        try {
            $payload = [
                'speed'  => 'normal',
                'reason' => $req->reason,
            ];

            if ($req->amountMinorUnits !== null) {
                $payload['amount'] = $req->amountMinorUnits;
            }
            if (!empty($req->notes)) {
                $payload['notes'] = $req->notes;
            }

            $refund = $this->getApi()->payment->fetch($req->paymentId)->refund($payload);

            return new RefundResult(
                refundId:         $refund->id,
                paymentId:        $refund->payment_id,
                amountMinorUnits: (int) $refund->amount,
                status:           $refund->status,
                createdAt:        (int) $refund->created_at,
                raw:              $this->toArray($refund),
            );
        } catch (\Exception $e) {
            throw new PaymentException(
                'Razorpay refund failed: ' . $e->getMessage(),
                0,
                $e,
            );
        }
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /**
     * Convert Razorpay SDK object to plain array for raw storage/logging.
     * The SDK returns objects with a toArray() method (or iterable attributes).
     */
    private function toArray(mixed $obj): array
    {
        if (is_array($obj)) {
            return $obj;
        }
        if (method_exists($obj, 'toArray')) {
            return $obj->toArray();
        }
        // Fallback: cast via JSON round-trip
        return json_decode((string) json_encode($obj), true) ?? [];
    }

    // -------------------------------------------------------------------------
    // Settlement model
    // -------------------------------------------------------------------------

    /**
     * @inheritdoc
     *
     * Razorpay is a GATEWAY provider — the consuming application is the
     * merchant of record and is responsible for GST invoicing/remittance.
     */
    public function settlementModel(): string
    {
        return 'gateway';
    }
}
