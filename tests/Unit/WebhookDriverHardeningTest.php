<?php

declare(strict_types=1);

namespace Tests\Unit;

use PHPUnit\Framework\TestCase;
use StoneScriptPay\DTO\WebhookRequest;
use StoneScriptPay\Drivers\PaypalDriver;
use StoneScriptPay\Drivers\RazorpayDriver;
use StoneScriptPay\Exceptions\MalformedWebhookException;

/**
 * Review hardening of the webhook side of the drivers: PayPal verifies the ORIGINAL bytes, the OAuth token is cached
 * with its TTL, and a signed event whose body cannot be normalised is reported as malformed (to be stored raw) instead
 * of escaping as an arbitrary exception.
 */
final class WebhookDriverHardeningTest extends TestCase
{
    private const SECRET = 'whsec';

    /** @param list<array{string,string}> $calls  [method, url] log; $verify decides the verify-webhook-signature answer */
    private function paypal(array &$calls, array &$bodies, int $tokenTtl = 32400, int &$now = 1000, array $verify = [[200, '{"verification_status":"SUCCESS"}']]): PaypalDriver
    {
        $verifyIdx = 0;

        return new PaypalDriver('https://api-m.sandbox.paypal.com', 'cid', 'sec', 'WH-1',
            static function (string $m, string $url, string $body, array $h, ?string $auth) use (&$calls, &$bodies, $tokenTtl, $verify, &$verifyIdx): array {
                $calls[] = "$m $url";
                if (str_contains($url, 'oauth2/token')) {
                    return [200, json_encode(['access_token' => 'tok' . count(array_filter($calls, fn($c) => str_contains($c, 'oauth2/token'))), 'expires_in' => $tokenTtl])];
                }
                if (str_contains($url, 'verify-webhook-signature')) {
                    $bodies[] = [$body, $h];

                    return $verify[min($verifyIdx++, count($verify) - 1)];
                }

                return [404, '{}'];
            },
            static function () use (&$now): int {
                return $now;
            },
        );
    }

    public function test_paypal_verification_sends_the_original_bytes_not_a_re_encoding(): void
    {
        $raw = '{"id":"WH-EVT-9",   "event_type":"PAYMENT.CAPTURE.COMPLETED","resource":{"id":"CAP9","amount":{"value":"10.10","currency_code":"USD"},"n":1.0e2,"u":"é\/x","custom_id":"ord_abc|t|plat"},"z":1}';
        $this->assertNotSame(json_encode(json_decode($raw, true)), $raw, 'the fixture really differs from its re-encoding');
        $calls = []; $bodies = []; $now = 1000;
        $d = $this->paypal($calls, $bodies, 32400, $now);
        $e = $d->handleWebhook(new WebhookRequest($raw, '', ['paypal-transmission-id' => 'T1', 'paypal-transmission-sig' => 'S"1', 'paypal-cert-url' => 'https://x', 'paypal-auth-algo' => 'SHA256withRSA', 'paypal-transmission-time' => '2026-10-10T00:00:00Z']));
        $this->assertSame('WH-EVT-9', $e->eventId);
        [$sent] = $bodies[0];
        $this->assertStringContainsString('"webhook_event":' . $raw . '}', $sent, 'the original body is spliced in verbatim');
        $decoded = json_decode($sent, true);
        $this->assertIsArray($decoded, 'and the verification request is still valid JSON');
        $this->assertSame('S"1', $decoded['transmission_sig'], 'header values are escaped, not concatenated');
        $this->assertSame('WH-1', $decoded['webhook_id']);
    }

    public function test_paypal_oauth_token_is_cached_until_shortly_before_it_expires(): void
    {
        $raw = '{"id":"WH-1","event_type":"X","resource":{}}';
        $calls = []; $bodies = []; $now = 1000;
        $d = $this->paypal($calls, $bodies, 600, $now);
        $tokenCalls = function () use (&$calls) { return count(array_filter($calls, fn($c) => str_contains($c, "oauth2/token"))); };
        $d->handleWebhook(new WebhookRequest($raw, '', []));
        $d->handleWebhook(new WebhookRequest($raw, '', []));
        $this->assertSame(1, $tokenCalls(), 'two webhooks, one token request');
        $now = 1000 + 600 - 61;      // 1s before the (ttl - 60s) refresh point
        $d->handleWebhook(new WebhookRequest($raw, '', []));
        $this->assertSame(1, $tokenCalls());
        $now = 1000 + 600 - 59;      // past it
        $d->handleWebhook(new WebhookRequest($raw, '', []));
        $this->assertSame(2, $tokenCalls(), 'refreshed after the TTL');
    }

    public function test_paypal_retries_once_with_a_fresh_token_after_a_401(): void
    {
        $raw = '{"id":"WH-1","event_type":"X","resource":{}}';
        $calls = []; $bodies = []; $now = 1000;
        $d = $this->paypal($calls, $bodies, 32400, $now, [[401, '{}'], [200, '{"verification_status":"SUCCESS"}']]);
        $d->handleWebhook(new WebhookRequest($raw, '', []));
        $this->assertCount(2, $bodies, 'verified on the second attempt');
        $this->assertSame(2, count(array_filter($calls, fn($c) => str_contains($c, 'oauth2/token'))), 'with a freshly requested token');
    }

    public function test_paypal_failed_verification_is_a_signature_error(): void
    {
        $calls = []; $bodies = []; $now = 1000;
        $d = $this->paypal($calls, $bodies, 32400, $now, [[200, '{"verification_status":"FAILURE"}']]);
        $this->expectException(\StoneScriptPay\Exceptions\SignatureVerificationException::class);
        $d->handleWebhook(new WebhookRequest('{"id":"x","event_type":"X"}', '', []));
    }

    private function signed(string $body): WebhookRequest
    {
        return new WebhookRequest($body, hash_hmac('sha256', $body, self::SECRET), ['X-Razorpay-Event-Id' => 'evt_h']);
    }

    public function test_razorpay_signed_but_misshapen_bodies_are_malformed_with_the_header_event_id(): void
    {
        $d = new RazorpayDriver('', '', self::SECRET);
        foreach (['not json', '"a string"', '{"event":["x"]}', '{"event":"payment.captured","payload":5}'] as $body) {
            try {
                $d->handleWebhook($this->signed($body));
                $this->fail("expected MalformedWebhookException for: {$body}");
            } catch (MalformedWebhookException $e) {
                $this->assertSame('evt_h', $e->eventId, $body);
            }
        }
    }

    public function test_each_driver_declares_its_own_signature_header(): void
    {
        $this->assertSame('x-razorpay-signature', (new RazorpayDriver('', '', 'w'))->webhookSignatureHeader());
        $this->assertSame('paypal-transmission-sig', (new PaypalDriver('https://api-m.sandbox.paypal.com', 'c', 's', 'w'))->webhookSignatureHeader());
    }

}
