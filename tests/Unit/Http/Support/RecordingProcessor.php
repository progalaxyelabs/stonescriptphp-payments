<?php

declare(strict_types=1);

namespace Tests\Http\Support;

use StoneScriptPay\DTO\WebhookEvent;
use StoneScriptPay\Http\Webhook\InboxEntry;
use StoneScriptPay\Http\Webhook\ProcessResult;
use StoneScriptPay\Http\Webhook\WebhookProcessor;

/** Counts how many times each event id was actually applied; can be told to fail. */
final class RecordingProcessor implements WebhookProcessor
{
    /** @var array<string,int> */
    public array $applied = [];
    public int $failTimes = 0;
    public ?ProcessResult $fixedResult = null;

    public function process(InboxEntry $entry, WebhookEvent $event): ProcessResult
    {
        if ($this->failTimes > 0) {
            $this->failTimes--;
            throw new \RuntimeException('processing blew up');
        }
        $key = $event->eventId ?? $entry->eventId;     // the gateway's event id when it sent one
        $this->applied[$key] = ($this->applied[$key] ?? 0) + 1;

        return $this->fixedResult ?? ProcessResult::applied();
    }

    public function total(): int
    {
        return array_sum($this->applied);
    }
}
