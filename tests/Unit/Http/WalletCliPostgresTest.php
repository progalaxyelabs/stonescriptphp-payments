<?php

declare(strict_types=1);

namespace Tests\Http;

use PHPUnit\Framework\TestCase;

/** Runs the real `bin/pay-wallet` tool as a subprocess against a real database. Skipped without PAYMENTS_TEST_PG_DSN. */
final class WalletCliPostgresTest extends TestCase
{
    private string $dir;
    private string $run;

    protected function setUp(): void
    {
        $dsn = getenv('PAYMENTS_TEST_PG_DSN');
        if ($dsn === false || $dsn === '' || !extension_loaded('pdo_pgsql')) {
            $this->markTestSkipped('PAYMENTS_TEST_PG_DSN / pdo_pgsql not available: the CLI tests did not run.');
        }
        $this->run = bin2hex(random_bytes(4));
        $this->dir = sys_get_temp_dir() . '/pay-wcli-' . $this->run;
        mkdir($this->dir);
        file_put_contents($this->dir . '/bootstrap.php', '<?php
require ' . var_export(dirname(__DIR__, 3) . '/vendor/autoload.php', true) . ';
require_once ' . var_export(__DIR__ . '/Support/FailableCaller.php', true) . ';
require_once ' . var_export(__DIR__ . '/Support/PdoFunctionCaller.php', true) . ';
$pdo = new PDO(getenv("PAYMENTS_TEST_PG_DSN"), null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
return new StoneScriptPay\Http\Wallet\WalletOperations(new Tests\Http\Support\PdoFunctionCaller($pdo));
');
    }

    protected function tearDown(): void
    {
        @unlink($this->dir . '/bootstrap.php');
        @unlink($this->dir . '/rows.json');
        @rmdir($this->dir);
    }

    /** @param list<string> $args @return array{0:int,1:string,2:string} */
    private function cli(array $args): array
    {
        $cmd = array_merge([PHP_BINARY, dirname(__DIR__, 3) . '/bin/pay-wallet'], $args, ['--bootstrap=' . $this->dir . '/bootstrap.php']);
        $p = proc_open($cmd, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
        $out = stream_get_contents($pipes[1]);
        $err = stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);

        return [proc_close($p), (string) $out, (string) $err];
    }

    public function test_grant_import_verify_close_meter_and_ledger_check_through_the_real_tool(): void
    {
        $t = sprintf('00000000-0000-0000-0000-%012x', hexdec(substr($this->run, 0, 6)) * 1000 + 1);
        [$rc, $out, $err] = $this->cli(['grant-free', "--tenant=$t", '--platform=wcli', "--key=k-$this->run", '--milli=2500', '--actor=cli-test', '--reason=welcome']);
        self::assertSame(0, $rc, $err);
        self::assertSame('applied', json_decode($out, true, 512, JSON_THROW_ON_ERROR)['o_outcome']);
        self::assertStringContainsString('wallet admin action by cli-test', $err);

        $t2 = sprintf('00000000-0000-0000-0000-%012x', hexdec(substr($this->run, 0, 6)) * 1000 + 2);
        file_put_contents($this->dir . '/rows.json', json_encode([['tenant_id' => $t2, 'platform_code' => 'wcli', 'credits' => '4.5']]));
        [$rc, $out, $err] = $this->cli(['import-opening', '--rows=@' . $this->dir . '/rows.json', '--scale=1000', '--actor=cli-test']);
        self::assertSame(0, $rc, $err);
        self::assertSame(4500, (int) json_decode($out, true)['o_total_milli']);
        [$rc] = $this->cli(['verify-opening', '--rows=@' . $this->dir . '/rows.json', '--scale=1000']);
        self::assertSame(0, $rc, 'the reconciliation gate passes when the wallets equal the legacy balances');
        file_put_contents($this->dir . '/rows.json', json_encode([['tenant_id' => $t2, 'platform_code' => 'wcli', 'credits' => '5.5']]));
        [$rc] = $this->cli(['verify-opening', '--rows=@' . $this->dir . '/rows.json', '--scale=1000']);
        self::assertSame(1, $rc, 'and exits 1 on any difference');

        [$rc, $out, $err] = $this->cli(['close-meter', "--tenant=$t", '--platform=wcli', '--meter-key=vm-9', '--actor=cli-test']);
        self::assertSame(0, $rc, $err);
        [$rc, $out] = $this->cli(['verify-ledger']);
        self::assertSame(0, $rc, 'the books balance: ' . $out);
        [$rc, , $err] = $this->cli(['grant-free', "--tenant=$t", '--platform=wcli', '--key=k2', '--milli=5', '--reason=x']);
        self::assertSame(1, $rc);
        self::assertStringContainsString('--actor', $err);
    }
}
