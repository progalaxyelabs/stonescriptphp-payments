<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

use StoneScriptPay\DTO\WebhookEvent;

/**
 * Applies one verified, durably stored webhook event.
 *
 * Contract: idempotent. The inbox claims a row before calling this, but a worker can still
 * crash after the effect and before the outcome is recorded, so the same event may arrive
 * here again; applying it twice must be a no-op (the library's capture function is).
 * Throw to mark the row failed (it is kept and replayable); never swallow an error and
 * return applied().
 */
interface WebhookProcessor
{
    public function process(InboxEntry $entry, WebhookEvent $event): ProcessResult;
}
