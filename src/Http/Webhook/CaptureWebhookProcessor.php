<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

use StoneScriptPay\Contracts\PaymentProvider;
use StoneScriptPay\DTO\WebhookEvent;
use StoneScriptPay\Http\Orders\CaptureApplier;
use StoneScriptPay\Http\Orders\CaptureOutcome;
use StoneScriptPay\Http\Orders\CapturedNotAppliedException;
use StoneScriptPay\Http\Orders\CapturePayment;
use StoneScriptPay\Http\Orders\RawPayloadAllowlist;
use StoneScriptPay\Http\Orders\RefundRequiredException;

/**
 * The webhook processor for payment captures: turns a verified payment.captured event into a
 * CapturePayment and applies it through the one exactly-once path (CaptureApplier).
 *
 * Wrap it in PlatformRoutingProcessor so events for other platforms and events with no routing
 * key never reach it. Idempotent by construction (a redelivery is already_applied).
 */
final class CaptureWebhookProcessor implements WebhookProcessor
{
    /** @param array<string,PaymentProvider> $providers keyed by gateway code, for the mode */
    public function __construct(
        private readonly CaptureApplier $applier,
        private readonly array $providers,
    ) {}

    public function process(InboxEntry $entry, WebhookEvent $event): ProcessResult
    {
        if (!$event->isPaymentCaptured()) {
            return ProcessResult::ignored("event type '{$event->type}' is not a capture");
        }
        if ($event->gatewayTxnRef === null || $event->amountMinorUnits === null || $event->currency === null || $event->capturedAt === null) {
            // a capture without its payment id, amount, currency or the gateway's own capture time
            // cannot be applied; never invent a value (the capture time is the gateway's, not ours)
            throw new \RuntimeException('payment.captured event is missing its payment id, amount, currency or capture time');
        }
        $provider = $this->providers[$entry->gatewayCode]
            ?? throw new \RuntimeException("No payment provider configured for gateway '{$entry->gatewayCode}'");

        // pay_captured_payments is an accounting record: keep only non-personal fields plus the hash of the full body
        // (the inbox entry id IS 'sha256:' + hash of the signed bytes).
        $bodyHash = str_starts_with($entry->eventId, 'sha256:') ? substr($entry->eventId, 7) : hash('sha256', $entry->rawBody);
        $outcome = $this->applier->apply(new CapturePayment(
            gatewayCode: $entry->gatewayCode,
            gatewayTxnRef: $event->gatewayTxnRef,
            orderRef: $event->orderRef,
            tenantId: $event->tenantId,
            platformCode: $event->platformCode,
            amountMinorUnits: $event->amountMinorUnits,
            currency: $event->currency,
            mode: $provider->mode(),
            capturedAt: $event->capturedAt,
            source: 'webhook:' . $entry->gatewayCode . ($event->capturedAtIsEstimate ? ':capture-time-estimated' : ''),
            rawJson: RawPayloadAllowlist::forPayment($this->paymentFields($event), $bodyHash),
        ));

        return match ($outcome->outcome) {
            CaptureOutcome::APPLIED => ProcessResult::applied("order {$outcome->orderRef}"),
            CaptureOutcome::ALREADY_APPLIED => ProcessResult::applied("order {$outcome->orderRef} (already applied)"),
            CaptureOutcome::REFUND_REQUIRED => throw new RefundRequiredException($outcome->detail ?? 'money arrived that could not be applied'),
            CaptureOutcome::CAPTURED_NOT_APPLIED => throw new CapturedNotAppliedException($outcome->detail ?? 'capture recorded but not applied'),
            default => ProcessResult::unattributed($outcome->detail ?? 'no matching order'),
        };
    }

    /**
     * The payment fields of the event, from the NORMALISED values (the provider-native payload is not stored). Only what the
     * allow-list will keep is assembled here.
     *
     * @return array<string,mixed>
     */
    private function paymentFields(WebhookEvent $event): array
    {
        return [
            'id' => $event->gatewayTxnRef,
            'amount' => $event->amountMinorUnits,
            'currency' => $event->currency,
            'status' => 'captured',
            'created_at' => $event->capturedAt?->getTimestamp(),
            'notes' => array_filter([
                'order_id' => $event->orderRef,
                'platform_code' => $event->platformCode,
                'tenant_id' => $event->tenantId,
            ], static fn($v) => $v !== null),
        ];
    }
}
