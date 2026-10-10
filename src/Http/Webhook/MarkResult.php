<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

/** Outcome of WebhookInboxStore::mark(). */
final class MarkResult
{
    public function __construct(
        public readonly string $status,
        public readonly bool $shouldAlert,
        public readonly ?string $alertKind = null,
    ) {}
}
