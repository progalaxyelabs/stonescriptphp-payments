<?php

declare(strict_types=1);

namespace Tests\Http;

use PHPUnit\Framework\TestCase;
use StoneScriptPay\Http\Entitlement\EntitlementOperations;
use Tests\Http\Support\PdoFunctionCaller;
use Tests\Http\Support\RecordingAlerts;

/** The operations facade over the real internal SQL functions (a direct connection). Skipped without PAYMENTS_TEST_PG_DSN. */
final class EntitlementOperationsPostgresTest extends TestCase
{
    private \PDO $pdo;
    private string $run;

    protected function setUp(): void
    {
        $dsn = getenv('PAYMENTS_TEST_PG_DSN');
        if ($dsn === false || $dsn === '' || !extension_loaded('pdo_pgsql')) {
            $this->markTestSkipped('PAYMENTS_TEST_PG_DSN / pdo_pgsql not available: the entitlement operations tests did not run.');
        }
        $this->pdo = new \PDO($dsn, null, null, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
        $this->run = bin2hex(random_bytes(4));
    }

    private function tenant(): string
    {
        return sprintf('00000000-0000-0000-0000-%012x', random_int(1, 0xffffffffffff));
    }

    public function test_comp_requires_an_actor_and_is_idempotent_and_the_tick_reaches_every_row(): void
    {
        $ops = new EntitlementOperations(new PdoFunctionCaller($this->pdo));
        $t = $this->tenant();
        $r = $ops->comp($t, 'opsplat', 'default', 'comp-pro', 5, "k-$this->run", 'operator', 'support goodwill');
        self::assertSame('applied', $r['o_outcome']);
        self::assertSame('already_applied', $ops->comp($t, 'opsplat', 'default', 'comp-pro', 5, "k-$this->run", 'operator', 'support goodwill')['o_outcome']);
        try {
            $ops->comp($t, 'opsplat', 'default', 'comp-pro', 5, "k2-$this->run", '  ', 'x');
            self::fail('an empty actor must be refused before the database is touched');
        } catch (\InvalidArgumentException $e) {
            self::assertStringContainsString('actor', $e->getMessage());
        }
        // a few lapsed rows, then a tick with a tiny batch must still reach all of them
        for ($i = 0; $i < 7; $i++) {
            $this->pdo->exec("SELECT * FROM _ent_comp_activate('" . $this->tenant() . "'::uuid, 'opsplat', 'default', 'x', 1, 'tk-$this->run-$i', 'operator', 'r', now())");
        }
        $res = $ops->tick(gmdate('c', time() + 6 * 86400), 3);
        self::assertGreaterThanOrEqual(8, $res['examined'], 'every row was examined across several small batches');
        self::assertGreaterThanOrEqual(8, $res['changed']);
    }

    public function test_a_billing_failure_is_logged_with_the_stable_token_alerted_and_does_not_stop_the_others(): void
    {
        $this->pdo->exec("SELECT _inv_issuer_upsert('ops-issuer', 'opsbill', NULL, 'Ops Pvt Ltd', 'regular', '29AAACX1234C1ZP', '29', 'Bengaluru', false, 'phpunit')");
        $this->pdo->exec("SELECT _inv_series_create('ops-inv-$this->run', 'ops-issuer', 'invoice', 'live', 'OP', '/', 5, true, 'phpunit')");
        $this->pdo->exec("INSERT INTO pricing_plans (id, name, is_subscription, is_active, is_trial, created_at, created_by) VALUES (95001, 'Ops postpaid', true, true, false, '2026-01-01', 'seed') ON CONFLICT DO NOTHING");
        $this->pdo->exec("INSERT INTO subscription_pricing_plans (id, pricing_plan_id, duration, duration_uom, amount, is_amount_tax_exclusive, is_post_paid, is_active, created_at, created_by) VALUES (95001, 95001, 1, 'month', 49900, true, true, true, '2026-01-01', 'seed') ON CONFLICT DO NOTHING");
        $ops = new EntitlementOperations(new PdoFunctionCaller($this->pdo), $alerts = new RecordingAlerts());
        $profile = ['series_code' => "ops-inv-$this->run", 'mode' => 'live', 'billing_country_code' => 'IN', 'billing_state' => 'Karnataka', 'hsn_sac' => '998314', 'gst_rate' => 0.18,
                    'buyer' => ['legal_name' => 'Ops Buyer', 'registration_status' => 'unregistered', 'address_state' => 'Karnataka']];
        $anchor = gmdate('c', time() - 40 * 86400);
        $good = $this->tenant();
        $bad = $this->tenant();
        $ops->enrollPostpaid($good, 'opsbill', 'default', 95001, $profile, $anchor, "e-good-$this->run", 'operator');
        $ops->enrollPostpaid($bad, 'opsbill', 'default', 95001, $profile, $anchor, "e-bad-$this->run", 'operator');
        $this->pdo->exec("UPDATE ent_entitlements SET billing_profile = jsonb_set(billing_profile, '{series_code}', '\"gone\"') WHERE tenant_id = '$bad'::uuid");
        $res = $ops->billingRun();
        self::assertGreaterThanOrEqual(1, $res['invoiced']);
        self::assertGreaterThanOrEqual(1, $res['failed']);
        $mine = array_values(array_filter($alerts->alerts, static fn (array $a): bool => $a['kind'] === 'entitlement.billing_failed'));
        self::assertNotSame([], $mine);
        self::assertStringContainsString('ENT_BILLING_FAILED', $mine[0]['detail']);
        self::assertSame(1, (int) $this->pdo->query("SELECT count(*) FROM inv_invoices WHERE tenant_id = '$good'::uuid AND charge_source = 'postpaid_cycle'")->fetchColumn());
        self::assertSame(0, (int) $this->pdo->query("SELECT count(*) FROM inv_invoices WHERE tenant_id = '$bad'::uuid")->fetchColumn(), 'a failed entitlement burned no number');
    }
}
