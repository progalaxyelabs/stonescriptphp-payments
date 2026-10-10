<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

use StoneScriptPay\DTO\WebhookEvent;

/**
 * Routes events on a gateway account shared by several platforms, before the real processor
 * sees them.
 *
 * Every order this library creates carries its platform code in the gateway notes, and the
 * drivers echo it back as WebhookEvent::$platformCode. For an event type this deployment
 * handles:
 *   - another platform's code                  -> foreign (recorded, never replayed, never alerted)
 *   - no platform code AND no order of ours     -> foreign (the same: not ours)
 *   - our platform code but no order reference  -> unattributed (recorded, alerted once, NEVER applied by guess)
 *   - one of our order references               -> handed to the inner processor, which resolves it or says
 *                                                  unattributed
 * Event types outside $handledTypes are ignored (recorded; nothing to do).
 */
final class PlatformRoutingProcessor implements WebhookProcessor
{
    /** @param list<string> $handledTypes Normalised WebhookEvent types the inner processor handles. */
    public function __construct(
        private readonly string $platformCode,
        private readonly WebhookProcessor $inner,
        private readonly array $handledTypes = ['payment.captured'],
    ) {}

    public function process(InboxEntry $entry, WebhookEvent $event): ProcessResult
    {
        if (!in_array($event->type, $this->handledTypes, true)) {
            return ProcessResult::ignored("event type '{$event->type}' has no handler");
        }
        $hasOrder = $event->orderRef !== null && str_starts_with($event->orderRef, 'ord_');
        $platform = $event->platformCode !== null && $event->platformCode !== '' ? $event->platformCode : null;

        if ($platform !== null && $platform !== $this->platformCode) {
            return ProcessResult::foreign($platform);                      // another platform's payment
        }
        if (!$hasOrder) {
            if ($platform === null) {
                // no routing key and no order of ours: this is somebody else's payment on a shared account,
                // not an anomaly of ours. Recorded, never replayed, never alerted.
                return ProcessResult::foreign(null, 'the event carries no platform routing key and no order of ours');
            }

            return ProcessResult::unattributed('the event names this platform but carries no order reference');
        }

        return $this->inner->process($entry, $event);                      // our order reference: SQL resolves it, or says unattributed
    }
}
