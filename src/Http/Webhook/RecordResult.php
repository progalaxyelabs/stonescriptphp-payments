<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

/** Outcome of WebhookInboxStore::record(): the durability point of the webhook flow. */
final class RecordResult
{
    public function __construct(
        public readonly int $id,
        public readonly bool $isNew,
        public readonly string $status,
        public readonly int $attempts,
        public readonly bool $shouldAlert,
    ) {}
}
