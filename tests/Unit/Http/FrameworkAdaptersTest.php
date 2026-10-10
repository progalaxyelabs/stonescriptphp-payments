<?php

declare(strict_types=1);

namespace Tests\Http;

use PHPUnit\Framework\TestCase;
use StoneScriptPay\Http\Entitlement\FrameworkMainDbScope;
use StoneScriptPay\Http\Webhook\DatabaseFnCaller;

/**
 * The adapters that touch the StoneScriptPHP framework (>= 12.0): FrameworkMainDbScope over the real gateway client, DatabaseFnCaller over
 * Database::fn() / Database::mutate() (with the framework's own Database::fake()). The framework is a DEV dependency, so a missing framework FAILS
 * these tests (PAYMENTS_SKIP_FRAMEWORK_TESTS=1 opts out on a machine that really has none).
 */
final class FrameworkAdaptersTest extends TestCase
{
    protected function setUp(): void
    {
        if (!class_exists(\StoneScriptPHP\Database::class)) {
            if (getenv('PAYMENTS_SKIP_FRAMEWORK_TESTS') === '1') {
                $this->markTestSkipped('PAYMENTS_SKIP_FRAMEWORK_TESTS=1');
            }
            self::fail('The StoneScriptPHP framework (>= 12.0) is a dev dependency of this package and is not installed.');
        }
        // the 12.0 persistence write boundary is the marker of the framework generation these adapters are written for (the tag is the version; a vendor
        // directory's Composer metadata can be stale, the loaded code cannot)
        self::assertTrue(method_exists(\StoneScriptPHP\Database::class, 'mutate') && class_exists(\StoneScriptPHP\Persistence\PersistenceException::class)
            && interface_exists(\StoneScriptPHP\Exceptions\PublicMessage::class), 'the adapters require StoneScriptPHP >= 12.0 (Database::mutate, PersistenceException, PublicMessage)');
    }

    protected function tearDown(): void
    {
        if (class_exists(\StoneScriptPHP\Database::class)) {
            \StoneScriptPHP\Database::clearFakeMode();
            $r = new \ReflectionProperty(\StoneScriptPHP\Database::class, '_instance');
            $r->setValue(null, null);
        }
    }

    /** a Database singleton whose transport is a real GatewayTransport over a real (never contacted) GatewayClient */
    private function gatewayClient(): \StoneScriptDB\GatewayClient
    {
        $client = new \StoneScriptDB\GatewayClient('http://127.0.0.1:1', 'plat', 'main', 'tenant', null);
        $db = (new \ReflectionClass(\StoneScriptPHP\Database::class))->newInstanceWithoutConstructor();
        $t = new \ReflectionProperty(\StoneScriptPHP\Database::class, 'transport');
        $t->setValue($db, new \StoneScriptPHP\Db\GatewayTransport($client));
        (new \ReflectionProperty(\StoneScriptPHP\Database::class, '_instance'))->setValue(null, $db);

        return $client;
    }

    public function test_the_main_database_scope_clears_the_tenant_for_the_call_and_restores_it(): void
    {
        $client = $this->gatewayClient();
        $client->setTenantId('tenant-schema-a');
        $seen = 'unset';
        $out = (new FrameworkMainDbScope())->run(function () use ($client, &$seen) {
            $seen = $client->getTenantId();

            return 'result';
        });
        self::assertSame('result', $out);
        self::assertNull($seen, 'inside the call the tenant context is cleared (the main database)');
        self::assertSame('tenant-schema-a', $client->getTenantId(), 'and restored afterwards');
    }

    public function test_the_tenant_is_restored_when_the_call_throws(): void
    {
        $client = $this->gatewayClient();
        $client->setTenantId('tenant-schema-b');
        try {
            (new FrameworkMainDbScope())->run(static function (): never { throw new \RuntimeException('boom'); });
            self::fail('the exception must propagate');
        } catch (\RuntimeException $e) {
            self::assertSame('boom', $e->getMessage());
        }
        self::assertSame('tenant-schema-b', $client->getTenantId());
    }

    public function test_database_fn_caller_calls_database_fn_with_scalar_arguments_and_raises_no_deprecation(): void
    {
        $calls = [];
        \StoneScriptPHP\Database::fake(['ent_get' => function (array $params) use (&$calls): array { $calls[] = $params; return [['o_status' => 'active', 'o_read_only' => false]]; }]);
        $deprecations = [];
        set_error_handler(static function (int $no, string $str) use (&$deprecations): bool { $deprecations[] = $str; return true; }, E_USER_DEPRECATED | E_DEPRECATED);
        try {
            $rows = (new DatabaseFnCaller())->call('ent_get', ['00000000-0000-0000-0000-000000000001', 'plat', 'default']);
        } finally {
            restore_error_handler();
        }
        self::assertSame('active', $rows[0]['o_status']);
        self::assertSame(['00000000-0000-0000-0000-000000000001', 'plat', 'default'], $calls[0]);
        self::assertSame([], $deprecations, 'the library passes scalars only, so the framework 12 raw-array deprecation never fires');
    }

    public function test_named_mutations_go_through_the_framework_write_boundary(): void
    {
        \StoneScriptPHP\Database::fake([
            'pay_apply_capture' => [['o_outcome' => 'applied']],
            'pay_webhook_claim' => [],
            'broken_write'      => [['error' => 'duplicate key value violates unique constraint "x"']],
        ]);
        $caller = new DatabaseFnCaller(['pay_apply_capture' => false, 'pay_webhook_claim' => true, 'broken_write' => false]);
        self::assertSame('applied', $caller->call('pay_apply_capture', ['a'])[0]['o_outcome']);
        self::assertSame([], $caller->call('pay_webhook_claim', [1, 120]), 'allowEmpty: a claim that finds nothing is not a failure');
        $this->expectException(\StoneScriptPHP\Persistence\PersistenceException::class);
        $caller->call('broken_write', ['x']);
    }

    public function test_an_empty_result_of_a_mutation_that_expects_a_row_is_a_persistence_failure(): void
    {
        \StoneScriptPHP\Database::fake(['pay_apply_capture' => []]);
        $this->expectException(\StoneScriptPHP\Persistence\PersistenceException::class);
        (new DatabaseFnCaller(['pay_apply_capture' => false]))->call('pay_apply_capture', ['a']);
    }
}
