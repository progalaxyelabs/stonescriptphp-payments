<?php

declare(strict_types=1);

namespace Tests\Http;

use PHPUnit\Framework\TestCase;
use StoneScriptPay\Http\Routes\PostWebhookRoute;
use StoneScriptPay\Http\Webhook\PlatformRoutingProcessor;
use StoneScriptPay\Http\Webhook\WebhookIngress;
use Tests\Http\Support\InMemoryInboxStore;
use Tests\Http\Support\RecordingAlerts;
use Tests\Http\Support\RecordingProcessor;
use Tests\Http\Support\WebhookFixtures;

/** The framework adapter renders the ingress answer in the framework's response shape. */
final class PostWebhookRouteTest extends TestCase
{
    protected function setUp(): void
    {
        if (!interface_exists(\StoneScriptPHP\IRouteHandler::class) || !function_exists('res_ok')) {
            $this->markTestSkipped('progalaxyelabs/stonescriptphp is not installed: the framework adapter is not testable here.');
        }
    }

    private function route(InMemoryInboxStore $store): PostWebhookRoute
    {
        $ingress = new WebhookIngress(
            ['razorpay' => WebhookFixtures::gateway()],
            $store,
            new PlatformRoutingProcessor('plat', new RecordingProcessor()),
            new RecordingAlerts(),
        );

        return new PostWebhookRoute('razorpay', $ingress);
    }

    /** HTTP status of a framework response: an instance property on current frameworks, a static on older ones. */
    private static function httpStatus(\StoneScriptPHP\ApiResponse $r): int
    {
        if (property_exists($r, 'httpStatusCode')) {
            return $r->httpStatusCode ?? 200;
        }

        return \StoneScriptPHP\ApiResponse::$httpStatusCode ?? 200;
    }

    public function test_ok_and_error_statuses_map_to_the_framework_response(): void
    {
        $body = WebhookFixtures::captured('pay_1', 'plat', 49900, 'ord_1');
        $route = $this->route($store = new InMemoryInboxStore());

        $ok = $route->handleRaw($body, WebhookFixtures::headers($body, 'evt_a'));
        $this->assertSame(200, self::httpStatus($ok));
        $this->assertSame('ok', $ok->status);
        $this->assertSame('applied', $ok->data['status']);

        $bad = $route->handleRaw($body, WebhookFixtures::headers($body, 'evt_b', false));
        $this->assertSame(401, self::httpStatus($bad));
        $this->assertSame('error', $bad->status);

        $store->failRecordTimes = 1;
        $down = $route->handleRaw($body, WebhookFixtures::headers($body, 'evt_c'));
        $this->assertSame(503, self::httpStatus($down), 'a store failure must surface as 503, not 200');
        $this->assertSame('error', $down->status);
    }
}
