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
    ) {}

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
