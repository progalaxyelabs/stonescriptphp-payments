<?php

declare(strict_types=1);

namespace Tests\Http;

use PHPUnit\Framework\TestCase;

/**
 * Runs the real `bin/pay-entitlement` tool as a subprocess against a real database: the bootstrap, the argument handling, the exit codes, and the
 * legacy import / delta sync / cutover gate end to end. Skipped without PAYMENTS_TEST_PG_DSN.
 */
final class EntitlementCliPostgresTest extends TestCase
{
    private \PDO $pdo;
    private string $dir;
    private string $run;

    protected function setUp(): void
    {
        $dsn = getenv('PAYMENTS_TEST_PG_DSN');
        if ($dsn === false || $dsn === '' || !extension_loaded('pdo_pgsql')) {
            $this->markTestSkipped('PAYMENTS_TEST_PG_DSN / pdo_pgsql not available: the CLI tests did not run.');
        }
        $this->pdo = new \PDO($dsn, null, null, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
        $this->run = bin2hex(random_bytes(4));
        $this->dir = sys_get_temp_dir() . '/pay-cli-' . $this->run;
        mkdir($this->dir);
        file_put_contents($this->dir . '/bootstrap.php', '<?php
require ' . var_export(dirname(__DIR__, 3) . '/vendor/autoload.php', true) . ';
require_once ' . var_export(__DIR__ . '/Support/FailableCaller.php', true) . ';
require_once ' . var_export(__DIR__ . '/Support/PdoFunctionCaller.php', true) . ';
$pdo = new PDO(getenv("PAYMENTS_TEST_PG_DSN"), null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
return new StoneScriptPay\Http\Entitlement\EntitlementOperations(new Tests\Http\Support\PdoFunctionCaller($pdo));
');
    }

    protected function tearDown(): void
    {
        @unlink($this->dir . '/bootstrap.php');
        @rmdir($this->dir);
    }

    /** @param list<string> $args @return array{0:int,1:string,2:string} */
    private function cli(array $args): array
    {
        $cmd = array_merge([PHP_BINARY, dirname(__DIR__, 3) . '/bin/pay-entitlement'], $args, ['--bootstrap=' . $this->dir . '/bootstrap.php']);
        $p = proc_open($cmd, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, null);
        $out = stream_get_contents($pipes[1]);
        $err = stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);

        return [proc_close($p), (string) $out, (string) $err];
    }

    private function uuid(int $n): string
    {
        return sprintf('00000000-0000-0000-0000-%012x', hexdec(substr($this->run, 0, 6)) * 1000 + $n);
    }

    public function test_import_sync_and_the_cutover_gate_through_the_real_tool(): void
    {
        $tbl = 'legacy_cli_' . $this->run;
        $plat = 'cli' . $this->run;
        $this->pdo->exec("CREATE TABLE $tbl (id SERIAL PRIMARY KEY, platform_code VARCHAR(50) NOT NULL, tenant_id TEXT NOT NULL, plan_code VARCHAR(50) NOT NULL DEFAULT 'annual',
            status VARCHAR(50) NOT NULL, started_at TIMESTAMPTZ NOT NULL, expires_at TIMESTAMPTZ, cancelled_at TIMESTAMPTZ)");
        $t1 = $this->uuid(1);
        $t2 = $this->uuid(2);
        $this->pdo->exec("INSERT INTO $tbl (platform_code, tenant_id, status, started_at, expires_at) VALUES
            ('$plat', '$t1', 'cancelled', now() - interval '30 days', now() + interval '20 days'),
            ('$plat', '$t2', 'active', now() - interval '30 days', now() + interval '300 days')");

        [$rc, $out, $err] = $this->cli(['import-legacy', "--legacy=$tbl", '--actor=cli-test']);
        self::assertSame(0, $rc, "import failed: $err");
        $r = json_decode($out, true, 512, JSON_THROW_ON_ERROR);
        self::assertSame(2, (int) $r['o_imported'], 'the first import brings both rows in (an explicit NULL time no longer breaks it)');
        self::assertSame('active', $this->pdo->query("SELECT status FROM ent_entitlements WHERE tenant_id = '$t1'::uuid AND platform_code = '$plat'")->fetchColumn(), 'a cancelled row with time left is active until then');
        self::assertStringContainsString('entitlement admin action by cli-test', $err, 'the action is logged with its actor');

        // the legacy writer renewed t2 after the import
        $this->pdo->exec("UPDATE $tbl SET expires_at = now() + interval '600 days' WHERE tenant_id = '$t2'");
        [$rc, $out] = $this->cli(['import-legacy', "--legacy=$tbl", '--actor=cli-test']);
        self::assertSame(0, (int) json_decode($out, true)['o_synced'], 'a plain re-import does not carry it');
        [$rc, $out, $err] = $this->cli(['import-legacy', "--legacy=$tbl", '--actor=cli-test', '--sync']);
        self::assertSame(0, $rc, $err);
        $r = json_decode($out, true, 512, JSON_THROW_ON_ERROR);
        self::assertSame(1, (int) $r['o_synced'], '--sync carries the renewal');
        [$rc, $out] = $this->cli(['import-legacy', "--legacy=$tbl", '--actor=cli-test', '--sync']);
        self::assertSame(0, (int) json_decode($out, true)['o_synced'], 'and nothing is left to sync');

        // the gate: the platform's missing mode must match the legacy one
        [$rc, , $err] = $this->cli(['cutover-check', "--legacy=$tbl", "--platform=$plat", '--legacy-missing-mode=allow']);
        self::assertSame(1, $rc, 'the gate refuses while the missing modes differ');
        self::assertStringContainsString('cutover blocked', $err);
        [$rc, $out, $err] = $this->cli(['missing-mode', "--platform=$plat", '--mode=allow', '--actor=cli-test']);
        self::assertSame(0, $rc, $err);
        [$rc, $out, $err] = $this->cli(['cutover-check', "--legacy=$tbl", "--platform=$plat", '--legacy-missing-mode=allow']);
        self::assertSame(0, $rc, "the gate should pass now: $err");
        self::assertStringContainsString('ok:', $out);
    }

    public function test_a_mutating_command_without_an_actor_is_refused_and_the_scheduler_commands_run(): void
    {
        [$rc, , $err] = $this->cli(['comp', '--tenant=' . $this->uuid(9), '--platform=cliplat', '--plan-ref=x', '--days=3', '--key=k-' . $this->run, '--reason=r']);
        self::assertSame(1, $rc);
        self::assertStringContainsString('--actor', $err);
        [$rc, $out] = $this->cli(['tick']);
        self::assertSame(0, $rc);
        self::assertArrayHasKey('examined', json_decode($out, true, 512, JSON_THROW_ON_ERROR));
        [$rc, $out] = $this->cli(['billing-run']);
        self::assertContains($rc, [0, 2]);
        self::assertArrayHasKey('invoiced', json_decode($out, true, 512, JSON_THROW_ON_ERROR));
        [$rc] = $this->cli(['bogus']);
        self::assertSame(1, $rc);
    }
}
