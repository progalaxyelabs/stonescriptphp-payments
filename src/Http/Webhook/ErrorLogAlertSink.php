<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

/** Default AlertSink: one error_log line. Replace it with a real pager in production. */
final class ErrorLogAlertSink implements AlertSink
{
    public function alert(string $kind, int $inboxId, string $gatewayCode, string $eventId, string $detail): void
    {
        error_log("[payments] ALERT {$kind} inbox={$inboxId} gateway={$gatewayCode} event={$eventId}: {$detail}");
    }
}
