<?php

declare(strict_types=1);

namespace StoneScriptPay\DTO;

/**
 * Parsed, verified webhook event returned by PaymentProvider::handleWebhook().
 *
 * By the time the driver returns this, the HMAC signature has been verified.
 * The route handler should dispatch on $type to update its domain model.
 *
 * Canonical event types (driver-normalised, NOT provider strings):
 *
 *   'payment.captured'       — payment fully captured; safe to activate subscription/fulfil order.
 *   'payment.failed'         — payment declined or timed out; mark as failed.
 *   'subscription.activated' — subscription created and active.
 *   'subscription.charged'   — renewal charge successful.
 *   'subscription.completed' — subscription ran to end of term.
 *   'subscription.cancelled' — subscription cancelled (effective at period end).
 *   'subscription.halted'    — subscription halted due to failed charges.
 *   'refund.created'         — refund initiated.
 *   'refund.processed'       — refund completed.
 *   'unknown'                — event type not covered above; inspect $raw.
 *
 * Beyond the provider-native $payload/$raw, settlement events (payment
 * captured / subscription charged) additionally carry a NORMALISED,
 * driver-populated projection ($invoiceRef/$gatewayTxnRef/
 * $amountMinorUnits/$currency/$capturedAt) so provider-agnostic glue (an
 * application's own billing orchestrator) can extract what it
 * needs without knowing each provider's native payload shape. These
 * fields are ADDITIVE and all nullable — existing consumers reading only
 * $payload/$raw are unaffected. A driver populates them only for event
 * types it can unambiguously map; they are null otherwise.
 *
 * @package StoneScriptPay\DTO
 */
final class WebhookEvent
{
    /**
     * @param string $type          Normalised event type (see class docblock).
     * @param string $providerEvent Raw event string from the provider (e.g. "payment.captured").
     * @param array  $payload       Parsed, verified payload extracted from the webhook body
     *                              (provider-NATIVE shape — differs per driver).
     * @param array  $raw           Full raw decoded webhook body for logging or custom handling.
     * @param ?string $invoiceRef        Normalised: the merchant-supplied reference the order/invoice
     *                                   was tagged with (Razorpay: notes.invoice_ref; PayPal: custom_id).
     * @param ?string $gatewayTxnRef     Normalised: the gateway's own payment/capture id — the
     *                                   idempotency key a replay should dedupe on.
     * @param ?int    $amountMinorUnits  Normalised: captured amount in minor units (paise/cents).
     * @param ?string $currency          Normalised: ISO 4217 currency code.
     * @param ?\DateTimeImmutable $capturedAt Normalised: the gateway's own capture time.
     * @param ?string $tenantId          Normalised (added 2026-09-22, TENANT ISOLATION):
     *                                   the tenant that initiated checkout, echoed back from
     *                                   order-creation notes/metadata (Razorpay: notes.tenant_id;
     *                                   PayPal: encoded into custom_id — see PaypalDriver). An
     *                                   app-side bridge to the framework's
     *                                   `StoneScriptPHP\Billing\CollectionOrchestrator` needs this
     *                                   to enforce the same tenant-ownership check on webhook
     *                                   settlement as on a direct call.
     * @param ?string $platformCode      Normalised: paired with $tenantId.
     * @param ?string $orderRef          Normalised: the library order reference (pay_orders.order_ref) this
     *                                   payment was collected for, echoed back by the gateway (Razorpay:
     *                                   notes.order_id; PayPal: the receipt part of custom_id). The routing
     *                                   key pay_apply_capture() resolves the order from. Null for a payment
     *                                   that did not originate from a library order.
     * @param bool $capturedAtIsEstimate True when $capturedAt is NOT the gateway's own capture time but the best
     *                                   available proxy (the webhook event's creation time, or the payment's
     *                                   creation time). Razorpay's webhook carries no capture timestamp. The flag is
     *                                   kept so an estimate is never mistaken for a fact; the event time is when
     *                                   the capture happened to within the delivery delay.
     * @param ?string $eventId           Normalised: the GATEWAY's unique id for this event delivery
     *                                   (Razorpay: the x-razorpay-event-id header; PayPal: the event's
     *                                   `id`). The key the webhook inbox dedupes redeliveries on. Null
     *                                   when the gateway did not supply one; the inbox then falls back
     *                                   to a hash of the raw body.
     */
    public function __construct(
        public readonly string $type,
        public readonly string $providerEvent,
        public readonly array $payload,
        public readonly array $raw = [],
        public readonly ?string $invoiceRef = null,
        public readonly ?string $gatewayTxnRef = null,
        public readonly ?int $amountMinorUnits = null,
        public readonly ?string $currency = null,
        public readonly ?\DateTimeImmutable $capturedAt = null,
        public readonly ?string $tenantId = null,
        public readonly ?string $platformCode = null,
        public readonly ?string $eventId = null,
        public readonly ?string $orderRef = null,
        public readonly bool $capturedAtIsEstimate = false,
    ) {}

    /**
     * JSON-safe projection, stored by the webhook inbox so a replay can rebuild the event
     * without the provider (the row only exists because the signature was verified).
     *
     * PRIVACY: only the NORMALISED fields are kept. The provider-native $payload and the full decoded
     * $raw body are deliberately NOT stored here: they carry the payer's personal data (e-mail, phone, card
     * and UPI details) and would duplicate the raw body that the inbox already holds, under its retention rule.
     *
     * @return array<string,mixed>
     */
    public function toArray(): array
    {
        return [
            'type' => $this->type,
            'provider_event' => $this->providerEvent,
            'invoice_ref' => $this->invoiceRef,
            'gateway_txn_ref' => $this->gatewayTxnRef,
            'amount_minor_units' => $this->amountMinorUnits,
            'currency' => $this->currency,
            'captured_at' => $this->capturedAt?->format(\DateTimeInterface::ATOM),
            'tenant_id' => $this->tenantId,
            'platform_code' => $this->platformCode,
            'event_id' => $this->eventId,
            'order_ref' => $this->orderRef,
            'captured_at_is_estimate' => $this->capturedAtIsEstimate,
        ];
    }

    /** @param array<string,mixed> $a  The shape produced by toArray(). */
    public static function fromArray(array $a): self
    {
        return new self(
            type: (string) ($a['type'] ?? 'unknown'),
            providerEvent: (string) ($a['provider_event'] ?? ''),
            payload: is_array($a['payload'] ?? null) ? $a['payload'] : [],
            raw: is_array($a['raw'] ?? null) ? $a['raw'] : [],
            invoiceRef: isset($a['invoice_ref']) ? (string) $a['invoice_ref'] : null,
            gatewayTxnRef: isset($a['gateway_txn_ref']) ? (string) $a['gateway_txn_ref'] : null,
            amountMinorUnits: isset($a['amount_minor_units']) ? (int) $a['amount_minor_units'] : null,
            currency: isset($a['currency']) ? (string) $a['currency'] : null,
            capturedAt: isset($a['captured_at']) && $a['captured_at'] !== ''
                ? new \DateTimeImmutable((string) $a['captured_at']) : null,
            tenantId: isset($a['tenant_id']) ? (string) $a['tenant_id'] : null,
            platformCode: isset($a['platform_code']) ? (string) $a['platform_code'] : null,
            eventId: isset($a['event_id']) ? (string) $a['event_id'] : null,
            orderRef: isset($a['order_ref']) ? (string) $a['order_ref'] : null,
            capturedAtIsEstimate: (bool) ($a['captured_at_is_estimate'] ?? false),
        );
    }

    /** True if this is a payment capture event that should trigger fulfilment. */
    public function isPaymentCaptured(): bool
    {
        return $this->type === 'payment.captured';
    }

    /** True if this is any subscription lifecycle event. */
    public function isSubscriptionEvent(): bool
    {
        return str_starts_with($this->type, 'subscription.');
    }

    /** True if this is any refund event. */
    public function isRefundEvent(): bool
    {
        return str_starts_with($this->type, 'refund.');
    }
}
