<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

/**
 * One claimed row of the webhook inbox (pay_webhook_inbox), as a processor sees it.
 */
final class InboxEntry
{
    /**
     * @param ?array<string,mixed> $event The normalised event (WebhookEvent::toArray() shape), or
     *                                    null when the signed body was unreadable.
     */
    public function __construct(
        public readonly int $id,
        public readonly string $gatewayCode,
        public readonly string $eventId,
        public readonly ?string $eventType,
        public readonly string $status,
        public readonly int $attempts,
        public readonly string $rawBody = '',
        public readonly ?array $event = null,
    ) {}
}
