<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Wallet;

use StoneScriptPay\Http\Webhook\SqlFunctionCaller;

/**
 * The operator / scheduler side of the wallet. Every method wraps an INTERNAL SQL function (leading underscore) and so needs a SqlFunctionCaller over
 * a DIRECT database connection (never the gateway's /call, which refuses internal functions). Run it through bin/pay-wallet, or from the platform's OWN
 * authorised admin route (the platform authenticates the operator and passes the authenticated id as $actor).
 *
 * The application-facing calls (wallet_drain, wallet_drain_cumulative, wallet_balance, wallet_forfeited, ledger_verify) are public SQL functions and
 * need no wrapper.
 */
final class WalletOperations
{
    public function __construct(private readonly SqlFunctionCaller $db) {}

    /** @return array<string,mixed> */
    public function grantFree(string $tenant, string $platform, string $key, int $milli, string $actor, string $reason, ?string $expiresAt = null): array
    {
        $this->act($actor, "grant-free tenant=$tenant platform=$platform milli=$milli key=$key");

        return $this->db->call('_wlt_grant_free', [$tenant, $platform, $key, $milli, gmdate('c'), $expiresAt, $actor, $reason])[0] ?? [];
    }

    public function createPack(int $pricingPlanId, string $name, int $creditsMilli, ?int $validityDuration, ?string $validityUom, string $actor): int
    {
        $this->act($actor, "create-pack plan=$pricingPlanId credits_milli=$creditsMilli");
        $r = $this->db->call('_wlt_pack_create', [$pricingPlanId, $name, $creditsMilli, $validityDuration, $validityUom, $actor]);

        return (int) (array_values($r[0] ?? [0])[0] ?? 0);
    }

    /**
     * @param list<array{tenant_id:string,platform_code:string,credits:string}> $rows legacy balances (credits as a decimal string)
     * @return array<string,mixed>
     */
    public function importOpening(array $rows, int $scale, string $actor): array
    {
        $this->act($actor, 'import-opening rows=' . count($rows) . " scale=$scale");

        return $this->db->call('_wlt_import_opening_balances', [json_encode($rows, JSON_THROW_ON_ERROR), $scale, $actor])[0] ?? [];
    }

    /**
     * The reconciliation gate: the differences between the legacy balances and the wallets (empty = they reconcile to the last milli-credit).
     *
     * @param list<array{tenant_id:string,platform_code:string,credits:string}> $rows
     * @return list<array<string,mixed>>
     */
    public function verifyOpening(array $rows, int $scale): array
    {
        return $this->db->call('_wlt_verify_opening', [json_encode($rows, JSON_THROW_ON_ERROR), $scale]);
    }

    public function markPlatformMigrated(string $platform, string $actor): string
    {
        $this->act($actor, "mark-migrated platform=$platform");
        $r = $this->db->call('_wlt_mark_platform_migrated', [$platform, $actor]);

        return (string) (array_values($r[0] ?? [''])[0] ?? '');
    }

    /**
     * The expiry sweep: forfeits expired credit, ONE WALLET PER TRANSACTION, in batches of $batch wallets, until none is due.
     *
     * @return array{wallets:int,forfeited_milli:int}
     */
    public function expire(?string $asOf = null, int $batch = 100): array
    {
        $out = ['wallets' => 0, 'forfeited_milli' => 0];
        for ($i = 0; $i < 100000; $i++) {                                  // bounded
            $now = $asOf ?? (string) (array_values($this->db->call('_pay_db_now', [])[0] ?? [''])[0] ?? '');
            $due = $this->db->call('_wlt_expire_due', [$now, $batch]);
            if ($due === []) {
                break;
            }
            foreach ($due as $d) {
                $out['forfeited_milli'] += (int) (array_values($this->db->call('_wlt_expire_one', [(int) array_values($d)[0], $now])[0] ?? [0])[0] ?? 0);
                $out['wallets']++;
            }
        }

        return $out;
    }

    /** Retires a meter (a reset or a rate change starts a NEW meter key). Returns whether it was open. */
    public function closeMeter(string $tenant, string $platform, string $meterKey, string $actor): bool
    {
        $this->act($actor, "close-meter tenant=$tenant platform=$platform meter=$meterKey");
        $r = $this->db->call('_wlt_meter_close', [$tenant, $platform, $meterKey, $actor]);
        $v = array_values($r[0] ?? [false])[0] ?? false;

        return $v === true || $v === 't' || $v === 'true' || $v === 1 || $v === '1';
    }

    /**
     * The nightly books check (cross-tenant, hence internal): the violations, empty when the ledger is sound.
     *
     * @return list<array<string,mixed>>
     */
    public function verifyLedger(): array
    {
        return $this->db->call('_ledger_verify', [null]);
    }

    private function act(string $actor, string $what): void
    {
        if (trim($actor) === '') {
            throw new \InvalidArgumentException('an actor is required for every wallet admin action');
        }
        error_log("[payments] wallet admin action by $actor: $what");
    }
}
