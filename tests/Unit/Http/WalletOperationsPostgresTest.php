<?php

declare(strict_types=1);

namespace Tests\Http;

use PHPUnit\Framework\TestCase;
use StoneScriptPay\Http\Wallet\WalletOperations;
use Tests\Http\Support\PdoFunctionCaller;

/** The wallet operations facade over the real internal SQL functions (a direct connection). Skipped without PAYMENTS_TEST_PG_DSN. */
final class WalletOperationsPostgresTest extends TestCase
{
    private \PDO $pdo;

    protected function setUp(): void
    {
        $dsn = getenv('PAYMENTS_TEST_PG_DSN');
        if ($dsn === false || $dsn === '' || !extension_loaded('pdo_pgsql')) {
            $this->markTestSkipped('PAYMENTS_TEST_PG_DSN / pdo_pgsql not available: the wallet operations tests did not run.');
        }
        $this->pdo = new \PDO($dsn, null, null, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
    }

    private function tenant(): string
    {
        return sprintf('00000000-0000-0000-0000-%012x', random_int(1, 0xffffffffffff));
    }

    public function test_grant_pack_import_verify_and_expire(): void
    {
        $ops = new WalletOperations(new PdoFunctionCaller($this->pdo));
        $t = $this->tenant();
        $k = bin2hex(random_bytes(4));
        self::assertSame('applied', $ops->grantFree($t, 'walplat', "g-$k", 1500, 'operator', 'welcome credit')['o_outcome']);
        self::assertSame('already_applied', $ops->grantFree($t, 'walplat', "g-$k", 1500, 'operator', 'welcome credit')['o_outcome']);
        try {
            $ops->grantFree($t, 'walplat', "g2-$k", 5, ' ', 'x');
            self::fail('an empty actor must be refused before the database is touched');
        } catch (\InvalidArgumentException) {
            self::addToAssertionCount(1);
        }
        $this->pdo->exec("INSERT INTO pricing_plans (id, name, is_subscription, is_active, is_trial, created_at, created_by) VALUES (96001, 'PHP wallet', false, true, false, '2026-01-01', 'seed') ON CONFLICT DO NOTHING");
        self::assertGreaterThan(0, $ops->createPack(96001, "Pack $k", 4000, null, null, 'operator'));

        $t2 = $this->tenant();
        $rows = [['tenant_id' => $t2, 'platform_code' => 'walplat', 'credits' => '12.5']];
        $imp = $ops->importOpening($rows, 1000, 'migration');
        self::assertSame(1, (int) $imp['o_imported']);
        self::assertSame(12500, (int) $imp['o_total_milli']);
        self::assertSame([], $ops->verifyOpening($rows, 1000), 'the reconciliation gate: legacy equals wallet');
        $rows[0]['credits'] = '13.5';
        self::assertCount(1, $ops->verifyOpening($rows, 1000), 'and it reports a legacy balance that moved');

        // an expiring grant, swept one wallet per transaction
        $t3 = $this->tenant();
        $this->pdo->exec("SELECT * FROM _wlt_grant_free('$t3'::uuid, 'walplat', 'exp-$k', 700, now() - interval '2 days', now() - interval '1 day', 'operator', 'expired promo')");
        $res = $ops->expire();
        self::assertGreaterThanOrEqual(1, $res['wallets']);
        self::assertGreaterThanOrEqual(700, $res['forfeited_milli']);
        self::assertSame(0, (int) $this->pdo->query('SELECT count(*) FROM _ledger_verify()')->fetchColumn(), 'the books balance');
    }
}
