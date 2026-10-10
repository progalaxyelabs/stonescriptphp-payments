<?php

declare(strict_types=1);

namespace StoneScriptPay\Drivers;

use Razorpay\Api\Api as RazorpayApi;
use Razorpay\Api\Errors\SignatureVerificationError;
use StoneScriptPay\Contracts\PaymentProvider;
use StoneScriptPay\DTO\CreateOrderRequest;
use StoneScriptPay\DTO\CreateSubscriptionRequest;
use StoneScriptPay\DTO\OrderResult;
use StoneScriptPay\DTO\PaymentDetails;
use StoneScriptPay\DTO\RefundRequest;
use StoneScriptPay\DTO\RefundResult;
use StoneScriptPay\DTO\SubscriptionResult;
use StoneScriptPay\DTO\VerificationResult;
use StoneScriptPay\DTO\VerifyRequest;
use StoneScriptPay\DTO\WebhookEvent;
use StoneScriptPay\DTO\WebhookRequest;
use StoneScriptPay\Exceptions\MalformedWebhookException;
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
     * @param ?string $mode         Optional explicit 'live' | 'test'. Needed only for a webhook-only
     *                               instance built with an empty $keyId; otherwise the mode is read from
     *                               the key id prefix (rzp_test_ / rzp_live_) and, when both are given,
     *                               they must agree.
     * @param ?\Closure $paymentFetcher Optional transport for fetchPayment(): fn(string $paymentId): array
     *                               returning the Razorpay payment entity as an array. Defaults to the SDK.
     *                               Exists for tests and custom transports.
     * @param ?\Closure $orderFinder Optional transport for findOrderByReceipt(): fn(string $receipt): list<array>
     *                               returning the matching Razorpay order entities. Defaults to the SDK.
     */
    public function __construct(
        private readonly string $keyId,
        private readonly string $keySecret,
        private readonly string $webhookSecret,
        private readonly ?string $mode = null,
        private readonly ?\Closure $paymentFetcher = null,
        private readonly ?\Closure $orderFinder = null,
    ) {
        if ($mode !== null && !in_array($mode, ['live', 'test'], true)) {
            throw new PaymentException("Razorpay mode must be 'live' or 'test' (got '{$mode}')");
        }
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
    // Mode, publishable key, payment lookup
    // -------------------------------------------------------------------------

    /** @inheritdoc */
    public function mode(): string
    {
        $fromKey = null;
        if (str_starts_with($this->keyId, 'rzp_test_')) {
            $fromKey = 'test';
        } elseif (str_starts_with($this->keyId, 'rzp_live_')) {
            $fromKey = 'live';
        }
        if ($fromKey !== null && $this->mode !== null && $this->mode !== $fromKey) {
            throw new PaymentException("Razorpay mode '{$this->mode}' contradicts the key id ({$fromKey} key)");
        }
        $mode = $fromKey ?? $this->mode;
        if ($mode === null) {
            throw new PaymentException(
                'Razorpay mode cannot be determined: the key id is not an rzp_test_/rzp_live_ key and no explicit mode was given'
            );
        }

        return $mode;
    }

    /** @inheritdoc */
    public function publishableKeyId(): string
    {
        return $this->keyId;
    }

    /**
     * @inheritdoc
     *
     * GET /payments/{id}. Razorpay status 'captured' is the only settled state; 'authorized' is a
     * hold. amount is in paise.
     */
    public function fetchPayment(string $paymentId): PaymentDetails
    {
        if (preg_match('/^pay_[A-Za-z0-9]+$/D', $paymentId) !== 1) {
            // never put an operator- or client-supplied string into an API path unchecked
            throw new PaymentException('Razorpay fetchPayment: not a Razorpay payment id (expected pay_ followed by letters and digits)');
        }
        try {
            $entity = $this->paymentFetcher !== null
                ? ($this->paymentFetcher)($paymentId)
                : $this->toArray($this->getApi()->payment->fetch($paymentId));
        } catch (PaymentException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new PaymentException('Razorpay payment lookup failed: ' . $e->getMessage(), 0, $e);
        }
        if (!is_array($entity) || !isset($entity['id'], $entity['amount'], $entity['currency'])) {
            throw new PaymentException('Razorpay payment lookup returned an unreadable payment');
        }

        $status = match ((string) ($entity['status'] ?? '')) {
            'captured' => 'captured',
            'authorized' => 'authorized',
            'failed' => 'failed',
            'refunded' => 'refunded',
            'created' => 'created',
            default => 'unknown',
        };
        // a partially refunded captured payment still reports 'captured' with amount_refunded > 0
        $notes = $entity['notes'] ?? [];

        return new PaymentDetails(
            paymentId: (string) $entity['id'],
            status: $status,
            amountMinorUnits: (int) $entity['amount'],
            currency: (string) $entity['currency'],
            gatewayOrderId: isset($entity['order_id']) ? (string) $entity['order_id'] : null,
            capturedAt: isset($entity['created_at']) && is_numeric($entity['created_at'])
                ? (new \DateTimeImmutable('@' . (int) $entity['created_at'])) : null,
            notes: is_array($notes) ? $notes : [],
            raw: $entity,
            amountRefundedMinorUnits: isset($entity['amount_refunded']) ? (int) $entity['amount_refunded'] : 0,
            capturedAtIsEstimate: true,      // Razorpay reports the payment's creation time, not a capture time
        );
    }

    /**
     * @inheritdoc
     *
     * GET /orders?receipt=... : an order creation that crashed after the gateway call but before our attach is found
     * again (our receipt is the order_ref) instead of creating a second gateway order.
     */
    public function findOrderByReceipt(string $receipt): ?OrderResult
    {
        try {
            $items = $this->orderFinder !== null
                ? ($this->orderFinder)($receipt)
                : ($this->toArray($this->getApi()->order->all(['receipt' => substr($receipt, 0, 40), 'count' => 5]))['items'] ?? []);
        } catch (PaymentException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new PaymentException('Razorpay order lookup failed: ' . $e->getMessage(), 0, $e);
        }
        foreach ($items as $o) {
            if (is_array($o) && ($o['receipt'] ?? null) === substr($receipt, 0, 40) && isset($o['id'], $o['amount'], $o['currency'])) {
                return new OrderResult((string) $o['id'], (int) $o['amount'], (string) $o['currency'], $receipt, $this->keyId, (string) ($o['status'] ?? ''), $o);
            }
        }

        return null;
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

        // Razorpay carries its unique event id in a header (x-razorpay-event-id), so it is
        // known even when the body turns out to be unreadable.
        $eventId = null;
        foreach ($req->headers as $name => $value) {
            if (strtolower((string) $name) === 'x-razorpay-event-id' && (string) $value !== '') {
                $eventId = (string) $value;
                break;
            }
        }

        // Parse payload. The signature has ALREADY verified: anything that goes wrong from here on (not JSON,
        // or JSON of an unexpected shape that trips normalisation) is an authentic event with a bad envelope,
        // which the caller must store raw, not drop. Hence the catch-all.
        try {
            $payload = json_decode($req->rawBody, true);
            if (!is_array($payload)) {
                throw new MalformedWebhookException('webhook body is not valid JSON', $eventId);
            }

            $providerEvent = $payload['event'] ?? '';
            if (!is_string($providerEvent)) {
                throw new MalformedWebhookException('webhook event name is not a string', $eventId);
            }
            $type = $this->normaliseEventType($providerEvent);
            $entityPayload = $payload['payload'] ?? [];
            if (!is_array($entityPayload)) {
                throw new MalformedWebhookException('webhook payload is not an object', $eventId);
            }

            [$invoiceRef, $gatewayTxnRef, $amountMinorUnits, $currency, $capturedAt, $tenantId, $platformCode] =
                $this->extractNormalisedFields($type, $entityPayload);

            // Capture time: the gateway's own if it ever sends one; otherwise the EVENT's creation time (the event is
            // raised when the capture happens); only as a last resort the payment's creation time. Anything but a
            // reported capture time is flagged as an estimate.
            $capturedAtIsEstimate = $capturedAt !== null;
            if ($type === 'payment.captured') {
                $entity = $entityPayload['payment']['entity'] ?? [];
                if (is_array($entity) && isset($entity['captured_at']) && is_numeric($entity['captured_at'])) {
                    $capturedAt = (new \DateTimeImmutable())->setTimestamp((int) $entity['captured_at']);
                    $capturedAtIsEstimate = false;
                } elseif (isset($payload['created_at']) && is_numeric($payload['created_at'])) {
                    $capturedAt = (new \DateTimeImmutable())->setTimestamp((int) $payload['created_at']);
                }
            }

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
                eventId:          $eventId,
                orderRef:         $type === 'payment.captured' && isset($entityPayload['payment']['entity']['notes']['order_id'])
                                      ? (string) $entityPayload['payment']['entity']['notes']['order_id'] : null,
                capturedAtIsEstimate: $capturedAtIsEstimate,
            );
        } catch (MalformedWebhookException $e) {
            throw $e;
        } catch (\Throwable $e) {
            throw new MalformedWebhookException('webhook body could not be read: ' . $e::class, $eventId);
        }
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

    /** @inheritdoc */
    public function webhookSignatureHeader(): string
    {
        return 'x-razorpay-signature';
    }

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
