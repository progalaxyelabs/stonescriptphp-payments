<?php

declare(strict_types=1);

namespace Tests\Http;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use StoneScriptPay\Http\Entitlement\EntitlementGuard;

final class EntitlementGuardTest extends TestCase
{
    /** @return array<string,mixed> */
    private static function row(array $o = []): array
    {
        return $o + ['o_found' => true, 'o_status' => 'active', 'o_read_only' => false, 'o_error_code' => null, 'o_reason' => null, 'o_is_trial' => false,
                     'o_period_end' => null, 'o_days_remaining' => null, 'o_overdue_since' => null];
    }

    public function test_a_writable_tenant_passes_with_ok_state(): void
    {
        $d = (new EntitlementGuard())->decide('POST', '/invoices', self::row());
        self::assertTrue($d->allowed);
        self::assertSame('ok', $d->stateHeader);
    }

    public function test_a_lookup_failure_fails_open(): void
    {
        self::assertTrue((new EntitlementGuard())->decide('POST', '/invoices', null)->allowed);
    }

    public function test_reads_work_but_writes_get_423_with_the_ent_get_error_code_when_read_only(): void
    {
        $ro = self::row(['o_status' => 'read_only', 'o_read_only' => true, 'o_error_code' => 'READ_ONLY_PLAN_ENDED', 'o_reason' => 'plan_ended', 'o_period_end' => '2026-10-01 10:00:00+05:30']);
        $g = new EntitlementGuard();
        foreach (['GET', 'HEAD', 'OPTIONS'] as $m) {
            self::assertTrue($g->decide($m, '/invoices', $ro)->allowed, "$m reads still work");
        }
        $d = $g->decide('POST', '/invoices', $ro);
        self::assertFalse($d->allowed);
        self::assertSame(423, $d->httpStatus);
        self::assertSame('READ_ONLY_PLAN_ENDED', $d->data['error_code']);
        self::assertSame('2026-10-01T04:30:00Z', $d->data['ended_at']);
        self::assertStringStartsWith('read_only; ended_at=2026-10-01T04:30:00Z; reason=plan_ended', $d->stateHeader);
    }

    #[DataProvider('codes')]
    public function test_each_reason_keeps_its_error_code(string $code): void
    {
        $d = (new EntitlementGuard())->decide('DELETE', '/things/1', self::row(['o_read_only' => true, 'o_status' => 'read_only', 'o_error_code' => $code]));
        self::assertSame($code, $d->data['error_code']);
    }

    /** @return iterable<string,array{0:string}> */
    public static function codes(): iterable
    {
        foreach (['READ_ONLY_TRIAL_EXPIRED', 'READ_ONLY_PLAN_ENDED', 'READ_ONLY_PAYMENT_OVERDUE', 'READ_ONLY_NO_SUBSCRIPTION'] as $c) {
            yield $c => [$c];
        }
    }

    #[DataProvider('writePaths')]
    public function test_the_write_allow_list(string $method, string $path, bool $allowed): void
    {
        $ro = self::row(['o_read_only' => true, 'o_status' => 'read_only', 'o_error_code' => 'READ_ONLY_PLAN_ENDED']);
        self::assertSame($allowed, (new EntitlementGuard(['POST /feedback']))->decide($method, $path, $ro)->allowed, "$method $path");
    }

    /** @return iterable<string,array{0:string,1:string,2:bool}> */
    public static function writePaths(): iterable
    {
        yield 'renewal prefix' => ['POST', '/subscription/renew', true];
        yield 'api-prefixed renewal' => ['POST', '/api/subscription/renew', true];
        yield 'export' => ['POST', '/export/csv', true];
        yield 'account deletion is method scoped' => ['POST', '/account/delete', true];
        yield 'DELETE /account exact' => ['DELETE', '/account', true];
        yield 'DELETE under /account is not allowed' => ['DELETE', '/account/profile', false];
        yield 'password reset prefix' => ['POST', '/account/password-reset/confirm', true];
        yield 'platform extra, right method' => ['POST', '/feedback', true];
        yield 'platform extra, wrong method' => ['PUT', '/feedback', false];
        yield 'an ordinary write' => ['POST', '/invoices', false];
        yield 'traversal fails closed' => ['POST', '/subscription/../invoices', false];
        yield 'encoded separator fails closed' => ['POST', '/subscription%2f..%2finvoices', false];
        yield 'look-alike prefix' => ['POST', '/subscriptions/x', false];
        yield 'the order route under /pay' => ['POST', '/pay/orders', true];
        yield 'an order poll under it' => ['POST', '/pay/orders/ord_1/capture', true];
        yield 'the payment route' => ['POST', '/pay/payments/verify', true];
        yield 'the quote route' => ['POST', '/pay/quote', true];
        yield 'the gateway webhook' => ['POST', '/pay/webhook/razorpay', true];
        yield 'api-prefixed library route' => ['POST', '/api/pay/orders', true];
        yield 'a generic /orders is NOT write-allowed' => ['POST', '/orders', false];
        yield 'nor /payments' => ['POST', '/payments', false];
        yield 'nor /quote' => ['POST', '/quote', false];
        yield 'nor /webhook' => ['POST', '/webhook/razorpay', false];
        yield 'a look-alike of the prefix' => ['POST', '/payroll', false];
    }

    public function test_the_allow_list_follows_a_configured_library_prefix(): void
    {
        $ro = self::row(['o_read_only' => true, 'o_status' => 'read_only', 'o_error_code' => 'READ_ONLY_PLAN_ENDED']);
        $g = new EntitlementGuard([], null, 7, '/billing');
        self::assertTrue($g->decide('POST', '/billing/orders', $ro)->allowed);
        self::assertFalse($g->decide('POST', '/pay/orders', $ro)->allowed, 'the default prefix is no longer allowed once the platform moved the library');
        self::assertSame('/pay/webhook/{gateway}', \StoneScriptPay\Http\Routes\RoutePaths::webhook());
        self::assertSame('/billing/orders', \StoneScriptPay\Http\Routes\RoutePaths::orders('billing/'));
        $this->expectException(\InvalidArgumentException::class);
        \StoneScriptPay\Http\Routes\RoutePaths::normalisePrefix('/../x');
    }

    public function test_exempt_paths_and_headers(): void
    {
        $g = new EntitlementGuard();
        self::assertTrue($g->isExempt('/health'));
        self::assertTrue($g->isExempt('/auth/login'));
        self::assertFalse($g->isExempt('/invoices'));
        self::assertStringStartsWith('plan_ending; ends_at=2026-10-05T00:00:00Z; days=3', $g->decide('POST', '/x', self::row(['o_days_remaining' => 3, 'o_period_end' => '2026-10-05 00:00:00+00']))->stateHeader);
        self::assertStringStartsWith('trial_ending', $g->decide('POST', '/x', self::row(['o_days_remaining' => 2, 'o_is_trial' => true, 'o_period_end' => '2026-10-05 00:00:00+00']))->stateHeader);
        self::assertSame('ok', $g->decide('POST', '/x', self::row(['o_days_remaining' => 30]))->stateHeader);
        $pd = $g->decide('POST', '/x', self::row(['o_status' => 'past_due', 'o_overdue_since' => '2026-02-01 00:00:00+00']));
        self::assertTrue($pd->allowed, 'past_due still writes');
        self::assertSame('past_due; reason=payment_overdue', $pd->stateHeader);
    }

    public function test_postgres_ent_get_row_shape_is_understood(): void
    {
        $dsn = getenv('PAYMENTS_TEST_PG_DSN');
        if ($dsn === false || $dsn === '' || !extension_loaded('pdo_pgsql')) {
            $this->markTestSkipped('PAYMENTS_TEST_PG_DSN / pdo_pgsql not available.');
        }
        $pdo = new \PDO($dsn, null, null, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
        $tenant = sprintf('00000000-0000-0000-0000-%012x', random_int(1, 0xffffffffffff));
        $row = $pdo->query("SELECT * FROM ent_get('$tenant'::uuid, 'phpplat')")->fetch(\PDO::FETCH_ASSOC);
        $d = (new EntitlementGuard())->decide('POST', '/x', $row);        // no entitlement + default missing mode = read-only
        self::assertFalse($d->allowed);
        self::assertSame('READ_ONLY_NO_SUBSCRIPTION', $d->data['error_code']);
        $pdo->exec("SELECT * FROM _ent_comp_activate('$tenant'::uuid, 'phpplat', 'default', 'comp', 30, 'php-" . $tenant . "', 'phpunit', 'test')");
        $row = $pdo->query("SELECT * FROM ent_get('$tenant'::uuid, 'phpplat')")->fetch(\PDO::FETCH_ASSOC);
        self::assertTrue((new EntitlementGuard())->decide('POST', '/x', $row)->allowed);
    }
}
