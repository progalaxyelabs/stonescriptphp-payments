<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

use StoneScriptPay\DTO\WebhookRequest;
use StoneScriptPay\Exceptions\MalformedWebhookException;
use StoneScriptPay\Exceptions\PaymentException;
use StoneScriptPay\Exceptions\SignatureVerificationException;
use StoneScriptPay\Exceptions\WebhookException;

/**
 * The webhook endpoint's logic, independent of any HTTP framework.
 *
 *   1. verify the signature (the driver does it, before parsing); a bad one is 401 and writes NOTHING
 *   2. store the event in the inbox - the durability point. If that fails, answer 503 so the
 *      gateway redelivers; never acknowledge an event that is not stored
 *   3. only then acknowledge (200), having processed it inline
 *
 * What happens after the event is stored never changes the answer: a processing failure leaves a
 * 'failed' row (kept, replayable, alerted once) and still answers 200, because the event is durable
 * and the gateway retrying would only redeliver a duplicate.
 *
 *   redelivered event id            200, no second row, nothing re-applied
 *   signed but unreadable body      stored raw as 'failed', alerted once, 200
 *   foreign / unattributed          recorded; unattributed alerts once, foreign never
 */
final class WebhookIngress
{
    /** Header names that are safe to keep with the stored event. */
    private const KEPT_HEADERS = [
        'content-type', 'user-agent', 'x-razorpay-event-id',
        'paypal-transmission-id', 'paypal-transmission-time', 'paypal-cert-url', 'paypal-auth-algo',
    ];

    private readonly InboxRunner $runner;
    private readonly AlertSink $alerts;

    /** @param array<string,WebhookGateway> $gateways keyed by gateway code */
    public function __construct(
        private readonly array $gateways,
        private readonly WebhookInboxStore $store,
        WebhookProcessor $processor,
        ?AlertSink $alerts = null,
        private readonly ?RateLimiter $limiter = null,
    ) {
        $this->alerts = $alerts ?? new ErrorLogAlertSink();
        $this->runner = new InboxRunner($store, $processor, $this->alerts);
    }

    /** @param array<string,string> $headers Request headers, any casing. */
    public function handle(string $gatewayCode, string $rawBody, array $headers, ?string $clientKey = null): IngressResult
    {
        $gateway = $this->gateways[$gatewayCode] ?? null;
        if ($gateway === null) {
            return new IngressResult(404, "Unknown gateway '{$gatewayCode}'");
        }
        if ($this->limiter !== null && !$this->limiter->allow($gatewayCode . '|' . ($clientKey ?? 'unknown'))) {
            return new IngressResult(429, 'Too many requests');
        }

        $h = [];
        foreach ($headers as $name => $value) {
            $h[strtolower((string) $name)] = (string) $value;
        }
        $signature = $h[$gateway->signatureHeader()] ?? '';

        $malformed = null;
        $event = null;
        try {
            $event = $gateway->provider->handleWebhook(new WebhookRequest($rawBody, $signature, $h));
        } catch (SignatureVerificationException $e) {
            error_log("[payments] webhook {$gatewayCode}: signature verification FAILED");
            return new IngressResult(401, 'Invalid signature');
        } catch (MalformedWebhookException $e) {
            $malformed = $e;            // authentic, unreadable: stored raw below, never dropped
        } catch (WebhookException | PaymentException $e) {
            error_log("[payments] webhook {$gatewayCode}: rejected before storage: " . $e->getMessage());
            return new IngressResult(400, 'Webhook could not be verified or read');
        }

        // The dedupe key is the SHA-256 of the raw body: the bytes the gateway's signature covers. The gateway's own
        // event id travels in an UNSIGNED header (Razorpay) and is only kept as metadata inside the stored event. Keyed on
        // the header, a forged id could pre-empt the genuine delivery of another event, or an old signed body replayed
        // under a fresh id would dodge dedupe; keyed on the signed bytes neither is possible. A genuine redelivery is
        // byte-identical, so it still dedupes.
        $eventId = self::bodyHash($rawBody);

        try {
            $rec = $this->store->record(
                $gatewayCode,
                $eventId,
                $event?->type,
                $event?->platformCode,
                $rawBody,
                array_intersect_key($h, array_flip(self::KEPT_HEADERS)),
                $event?->toArray(),
                $malformed !== null ? 'failed' : 'received',
                $malformed?->getMessage(),
            );
        } catch (\Throwable $e) {
            // NOT stored, so NOT acknowledged: the gateway will redeliver.
            error_log("[payments] webhook {$gatewayCode}/{$eventId}: could not be stored: " . $e->getMessage());
            return new IngressResult(503, 'Temporarily unable to store the event; please redeliver');
        }

        if ($rec->shouldAlert) {
            try {
                $this->alerts->alert('webhook.malformed', $rec->id, $gatewayCode, $eventId, (string) $malformed?->getMessage());
                $this->store->alertSent($rec->id, 'webhook.malformed');     // only after the sink succeeded
            } catch (\Throwable $e) {
                error_log('[payments] malformed-webhook alert not delivered (it stays due): ' . $e->getMessage());
            }
        }

        if (!$rec->isNew && $rec->status !== 'received') {
            return new IngressResult(200, 'Already received', ['inbox_id' => $rec->id, 'status' => $rec->status, 'duplicate' => true]);
        }
        if ($malformed !== null) {
            return new IngressResult(200, 'Received', ['inbox_id' => $rec->id, 'status' => 'failed']);
        }

        // new, or an earlier delivery stored it and was interrupted before recording an outcome
        $final = $this->runner->run($rec->id);

        return new IngressResult(200, 'Received', [
            'inbox_id' => $rec->id,
            'status' => $final ?? 'received',
            'duplicate' => !$rec->isNew,
        ]);
    }

    private static function bodyHash(string $rawBody): string
    {
        return 'sha256:' . hash('sha256', $rawBody);
    }
}
