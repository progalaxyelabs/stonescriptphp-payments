<?php

declare(strict_types=1);

namespace Tests\Http\Support;

use StoneScriptPay\Http\Webhook\AlertSink;

final class RecordingAlerts implements AlertSink
{
    /** @var list<array{kind:string,id:int,event:string,detail:string}> */
    public array $alerts = [];

    public function alert(string $kind, int $inboxId, string $gatewayCode, string $eventId, string $detail): void
    {
        $this->alerts[] = ['kind' => $kind, 'id' => $inboxId, 'event' => $eventId, 'detail' => $detail];
    }

    /** @return list<string> */
    public function kinds(): array
    {
        return array_column($this->alerts, 'kind');
    }
}
