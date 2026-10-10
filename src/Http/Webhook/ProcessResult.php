<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

/**
 * What a WebhookProcessor decided about one verified event.
 *
 *   applied       the domain effect happened (exactly once - the processor must be idempotent)
 *   ignored       a verified event this deployment has no handler for
 *   foreign       addressed to another platform, or carrying no routing key and no order of ours at all (a gateway
 *                 account shared between products): recorded, never replayed, never alerted
 *   unattributed  RESERVED for an event that carries our platform code or one of our order references that does
 *                 not resolve: NEVER applied by guess; recorded, and alerted once
 */
final class ProcessResult
{
    public const APPLIED = 'applied';
    public const IGNORED = 'ignored';
    public const FOREIGN = 'foreign';
    public const UNATTRIBUTED = 'unattributed';

    private function __construct(
        public readonly string $status,
        public readonly ?string $detail,
        public readonly ?string $platformCode,
    ) {}

    public static function applied(?string $detail = null): self
    {
        return new self(self::APPLIED, $detail, null);
    }

    public static function ignored(?string $detail = null): self
    {
        return new self(self::IGNORED, $detail, null);
    }

    public static function foreign(?string $platformCode, ?string $why = null): self
    {
        return new self(self::FOREIGN, $why ?? "event addressed to platform '{$platformCode}'", $platformCode);
    }

    public static function unattributed(string $reason): self
    {
        return new self(self::UNATTRIBUTED, $reason, null);
    }
}
