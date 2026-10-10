<?php

declare(strict_types=1);

namespace Tests\Http;

use PHPUnit\Framework\TestCase;
use StoneScriptPay\Http\Entitlement\EntitlementGuard;
use StoneScriptPay\Http\Entitlement\EntitlementMiddleware;
use StoneScriptPay\Http\Entitlement\InMemoryDecisionCache;
use StoneScriptPay\Http\Entitlement\LookupFailure;
use StoneScriptPay\Http\Entitlement\MainDbScope;
use StoneScriptPay\Http\Webhook\SqlFunctionCaller;
use Tests\Http\Support\RecordingAlerts;

/**
 * The framework adapter, against a fake ent_get. The framework is a DEV dependency of this package, so these tests FAIL (never skip) when it is
 * missing: a skipped adapter test in CI is a silent hole. (PAYMENTS_SKIP_FRAMEWORK_TESTS=1 opts out on a machine that really has no framework.)
 */
final class EntitlementMiddlewareTest extends TestCase
{
    private \StoneScriptPHP\ApiResponse $marker;
    /** @var list<array{0:string,1:string}> */
    private array $headers = [];
    private int $clock = 1_000_000;

    protected function setUp(): void
    {
        if (!interface_exists(\StoneScriptPHP\Routing\MiddlewareInterface::class)) {
            if (getenv('PAYMENTS_SKIP_FRAMEWORK_TESTS') === '1') {
                $this->markTestSkipped('PAYMENTS_SKIP_FRAMEWORK_TESTS=1');
            }
            self::fail('The StoneScriptPHP framework is a dev dependency of this package and is not installed: the entitlement middleware adapter cannot be tested. Run composer install (require-dev).');
        }
        InMemoryDecisionCache::reset();
        $this->headers = [];
        $this->marker = new \StoneScriptPHP\ApiResponse('ok', 'next', [], 200);
    }

    private static function readOnlyRow(): array
    {
        return ['o_found' => true, 'o_status' => 'read_only', 'o_read_only' => true, 'o_error_code' => 'READ_ONLY_PAYMENT_OVERDUE', 'o_reason' => 'payment_overdue',
                'o_is_trial' => false, 'o_period_end' => null, 'o_days_remaining' => null, 'o_overdue_since' => null];
    }

    private static function openRow(): array
    {
        return ['o_found' => true, 'o_status' => 'active', 'o_read_only' => false, 'o_error_code' => null, 'o_reason' => null, 'o_is_trial' => false,
                'o_period_end' => null, 'o_days_remaining' => null, 'o_overdue_since' => null];
    }

    /** @param callable(string,array):array $impl */
    private function db(callable $impl): SqlFunctionCaller
    {
        return new class($impl) implements SqlFunctionCaller {
            public array $calls = [];
            public function __construct(private $impl) {}
            public function call(string $function, array $args): array
            {
                $this->calls[] = [$function, $args];
                return ($this->impl)($function, $args);
            }
        };
    }

    private function mw(SqlFunctionCaller $db, ?MainDbScope $scope = null, ?RecordingAlerts $alerts = null, int $alertAfter = 3): EntitlementMiddleware
    {
        return new EntitlementMiddleware($db, new EntitlementGuard(), static fn (array $r): ?array => isset($r['tenant']) ? [$r['tenant'], 'plat'] : null, 'default',
            $scope, $alerts, new InMemoryDecisionCache(600), $alertAfter, fn (): int => $this->clock, function (string $n, string $v): void { $this->headers[] = [$n, $v]; });
    }

    private function post(EntitlementMiddleware $mw, string $path = '/invoices', string $method = 'POST')
    {
        return $mw->handle(['method' => $method, 'path' => $path, 'tenant' => 't1'], fn (array $r) => $this->marker);
    }

    public function test_the_lookup_runs_on_the_main_database_and_the_tenant_context_is_restored(): void
    {
        $log = [];
        $scope = new class($log) implements MainDbScope {
            public function __construct(public array &$log) {}
            public function run(callable $fn): mixed
            {
                $this->log[] = 'tenant-context-cleared';
                try {
                    return $fn();
                } finally {
                    $this->log[] = 'tenant-context-restored';
                }
            }
        };
        $db = $this->db(function (string $f, array $a) use (&$log): array { $log[] = "call:$f"; return [self::openRow()]; });
        $resp = $this->post($this->mw($db, $scope));
        self::assertSame($this->marker, $resp);
        self::assertSame(['tenant-context-cleared', 'call:ent_get', 'tenant-context-restored'], $log, 'ent_get is called INSIDE the cleared (main-database) context');
    }

    public function test_the_tenant_context_is_restored_even_when_the_lookup_throws(): void
    {
        $log = [];
        $scope = new class($log) implements MainDbScope {
            public function __construct(public array &$log) {}
            public function run(callable $fn): mixed
            {
                $this->log[] = 'cleared';
                try {
                    return $fn();
                } finally {
                    $this->log[] = 'restored';
                }
            }
        };
        $db = $this->db(static fn (): array => throw new \RuntimeException('connection refused'));
        $this->post($this->mw($db, $scope));
        self::assertSame(['cleared', 'restored'], $log);
    }

    public function test_object_rows_and_pre_decoded_json_rows_are_normalised(): void
    {
        $asObject = (object) self::readOnlyRow();
        self::assertSame('read_only', EntitlementMiddleware::normaliseRow([$asObject])['o_status']);
        self::assertSame('read_only', EntitlementMiddleware::normaliseRow($asObject)['o_status']);
        self::assertSame('read_only', EntitlementMiddleware::normaliseRow([['ent_get' => json_encode(self::readOnlyRow())]])['o_status']);
        self::assertSame('read_only', EntitlementMiddleware::normaliseRow([['ent_get' => (object) self::readOnlyRow()]])['o_status']);
        self::assertNull(EntitlementMiddleware::normaliseRow([]));
        self::assertNull(EntitlementMiddleware::normaliseRow([[]]));
        self::assertNull(EntitlementMiddleware::normaliseRow([['unrelated' => 1]]));
        $resp = $this->post($this->mw($this->db(static fn (): array => [(object) self::readOnlyRow()])));
        self::assertNotSame($this->marker, $resp, 'an object row is decided on, not ignored');
        self::assertSame('error', $resp->status);
    }

    public function test_a_read_only_write_is_refused_and_a_read_passes_with_the_state_header(): void
    {
        $mw = $this->mw($this->db(static fn (): array => [self::readOnlyRow()]));
        self::assertNotSame($this->marker, $this->post($mw));
        self::assertSame($this->marker, $this->post($mw, '/invoices', 'GET'));
        self::assertStringStartsWith('read_only', $this->headers[0][1]);
        self::assertSame($this->marker, $this->post($mw, '/pay/orders', 'POST'), 'a read-only tenant can always create an order');
    }

    public function test_an_empty_result_is_a_deploy_error_logged_alerted_and_still_served(): void
    {
        $alerts = new RecordingAlerts();
        $mw = $this->mw($this->db(static fn (): array => []), null, $alerts);
        self::assertSame($this->marker, $this->post($mw), 'the request is served');
        self::assertSame([], $this->headers, 'with no state header: the state is unknown');
        self::assertSame(['entitlement.deploy_error'], $alerts->kinds());
        self::assertStringContainsString(EntitlementMiddleware::TOKEN_DEPLOY, $alerts->alerts[0]['detail']);
        $this->post($mw);
        self::assertCount(1, $alerts->alerts, 'alerted at most once in 5 minutes');
        $this->clock += 301;
        $this->post($mw);
        self::assertCount(2, $alerts->alerts, 'and again after the quiet period');
    }

    public function test_the_deploy_alert_is_throttled_per_worker_not_per_request(): void
    {
        $alerts = new RecordingAlerts();
        // a brand new middleware object per request, the way PHP-FPM builds them: the throttle must live in the shared cache, not on the object
        for ($i = 0; $i < 5; $i++) {
            $mw = $this->mw($this->db(static fn (): array => []), null, $alerts);
            self::assertSame($this->marker, $this->post($mw));
        }
        self::assertCount(1, $alerts->alerts, 'five requests in a bad deployment raise ONE alert');
        $this->clock += 301;
        $this->post($this->mw($this->db(static fn (): array => []), null, $alerts));
        self::assertCount(2, $alerts->alerts, 'and one more after the 5-minute window');
    }

    public function test_a_missing_config_row_or_function_is_a_deploy_error_not_a_blip(): void
    {
        foreach ([new \PDOException('SQLSTATE[PY050]: pay_config "billing_timezone" is missing'), new \RuntimeException('function ent_get(uuid, unknown) does not exist')] as $e) {
            self::assertSame(LookupFailure::DEPLOY, LookupFailure::classify($e));
        }
        foreach ([new \RuntimeException('connection refused'), new \RuntimeException('Connection timed out after 5s'), new \RuntimeException('statement timeout')] as $e) {
            self::assertSame(LookupFailure::TRANSPORT, LookupFailure::classify($e));
        }
        self::assertSame(LookupFailure::UNKNOWN, LookupFailure::classify(new \LogicException('odd')));
        $alerts = new RecordingAlerts();
        $mw = $this->mw($this->db(static fn (): array => throw new \RuntimeException('function ent_get does not exist')), null, $alerts);
        self::assertSame($this->marker, $this->post($mw));
        self::assertSame(['entitlement.deploy_error'], $alerts->kinds());
    }

    public function test_a_blip_serves_the_last_known_decision_for_ten_minutes_then_goes_open(): void
    {
        $fail = false;
        $mw = $this->mw($this->db(static function () use (&$fail): array { if ($fail) { throw new \RuntimeException('connection refused'); } return [self::readOnlyRow()]; }));
        self::assertNotSame($this->marker, $this->post($mw), 'a lapsed tenant is read-only');
        $fail = true;
        $this->headers = [];
        $this->clock += 300;
        self::assertNotSame($this->marker, $this->post($mw), 'during a blip the lapsed tenant STAYS read-only (last-known decision)');
        self::assertSame([], $this->headers, 'and no state header is sent for a decision that may be stale');
        self::assertSame($this->marker, $this->post($mw, '/invoices', 'GET'), 'reads still pass');
        $this->clock += 400;                                  // 700 s after the last good answer
        self::assertSame($this->marker, $this->post($mw), 'after 10 minutes with no good answer it fails open');
    }

    public function test_an_unknown_tenant_with_a_transport_failure_fails_open_without_a_header(): void
    {
        $mw = $this->mw($this->db(static fn (): array => throw new \RuntimeException('connection refused')));
        self::assertSame($this->marker, $this->post($mw));
        self::assertSame([], $this->headers);
    }

    public function test_consecutive_failures_alert_once_at_the_threshold_and_a_success_resets_the_count(): void
    {
        $alerts = new RecordingAlerts();
        $fail = true;
        $mw = $this->mw($this->db(static function () use (&$fail): array { if ($fail) { throw new \RuntimeException('connection refused'); } return [self::openRow()]; }), null, $alerts, 3);
        for ($i = 0; $i < 5; $i++) {
            $this->post($mw);
        }
        self::assertSame(['entitlement.lookup_failing'], $alerts->kinds(), 'one alert, at the third consecutive failure');
        self::assertStringContainsString(EntitlementMiddleware::TOKEN_FAILING, $alerts->alerts[0]['detail']);
        $fail = false;
        $this->post($mw);
        $fail = true;
        for ($i = 0; $i < 3; $i++) {
            $this->post($mw);
        }
        self::assertSame(['entitlement.lookup_failing', 'entitlement.lookup_failing'], $alerts->kinds(), 'a success resets the streak, so the next streak alerts again');
    }

    public function test_exempt_unauthenticated_requests_never_reach_the_database(): void
    {
        $db = $this->db(static fn (): array => [self::readOnlyRow()]);
        $mw = $this->mw($db);
        self::assertSame($this->marker, $mw->handle(['method' => 'POST', 'path' => '/health', 'tenant' => 't1'], fn () => $this->marker));
        self::assertSame($this->marker, $mw->handle(['method' => 'POST', 'path' => '/invoices'], fn () => $this->marker));
        self::assertSame([], $db->calls);
    }
}
