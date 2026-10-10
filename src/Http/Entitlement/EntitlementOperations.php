<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Entitlement;

use StoneScriptPay\Http\Webhook\AlertSink;
use StoneScriptPay\Http\Webhook\SqlFunctionCaller;

/**
 * The operator / scheduler side of the entitlement store. Every method wraps an INTERNAL SQL function (leading underscore), so it needs a
 * SqlFunctionCaller over a DIRECT database connection (the platform's own credentials on the server), never the gateway's /call, which refuses
 * internal functions. Run it through bin/pay-entitlement, or call it from the platform's OWN authorised admin route (the platform authenticates
 * the operator and passes the authenticated id as $actor; the library does not authenticate anyone).
 *
 * Mutating methods require a non-empty $actor, which is written to the audit trail and logged.
 */
final class EntitlementOperations
{
    public function __construct(
        private readonly SqlFunctionCaller $db,
        private readonly ?AlertSink $alerts = null,
    ) {}

    /** @return array<string,mixed> */
    public function comp(string $tenant, string $platform, string $product, string $planRef, int $days, string $key, string $actor, string $reason): array
    {
        return $this->one($this->act($actor, "comp tenant=$tenant platform=$platform days=$days key=$key"), '_ent_comp_activate', [$tenant, $platform, $product, $planRef, $days, $key, $actor, $reason]);
    }

    /** @return array<string,mixed> */
    public function setStatus(string $tenant, string $platform, string $product, string $status, string $key, string $actor, string $reason): array
    {
        return $this->one($this->act($actor, "status tenant=$tenant platform=$platform status=$status key=$key"), '_ent_set_status', [$tenant, $platform, $product, $status, $key, $actor, $reason]);
    }

    /**
     * @param array<string,mixed> $profile series_code, mode, buyer{...}, billing_country_code, billing_state, hsn_sac, gst_rate, ...
     * @return array<string,mixed>
     */
    public function enrollPostpaid(string $tenant, string $platform, string $product, int $planId, array $profile, string $anchor, string $key, string $actor): array
    {
        return $this->one($this->act($actor, "enroll-postpaid tenant=$tenant platform=$platform plan=$planId key=$key"), '_ent_enroll_postpaid',
            [$tenant, $platform, $product, $planId, json_encode($profile, JSON_THROW_ON_ERROR), $anchor, $key, $actor]);
    }

    /**
     * @param ?array<string,mixed> $profile
     * @return array<string,mixed>
     */
    public function setBillingMode(string $tenant, string $platform, string $product, string $mode, ?int $planId, ?array $profile, ?string $anchor, ?string $periodEnd, string $key, string $actor, string $reason): array
    {
        return $this->one($this->act($actor, "billing-mode tenant=$tenant platform=$platform mode=$mode key=$key"), '_ent_set_billing_mode',
            [$tenant, $platform, $product, $mode, $planId, $profile === null ? null : json_encode($profile, JSON_THROW_ON_ERROR), $anchor, $periodEnd, $key, $actor, $reason]);
    }

    public function setMissingMode(string $platform, string $mode, string $actor): string
    {
        $this->act($actor, "missing-mode platform=$platform mode=$mode");
        $r = $this->db->call('_ent_set_missing_mode', [$platform, $mode, $actor]);

        return (string) (array_values($r[0] ?? [''])[0] ?? '');
    }

    /** The hard gate before a legacy table is replaced by the compatibility view. Throws (PY067) unless it passes. */
    public function cutoverCheck(string $legacyTable, string $platform, string $legacyMissingMode): string
    {
        $r = $this->db->call('_ent_cutover_check', [$legacyTable, $platform, $legacyMissingMode]);

        return (string) (array_values($r[0] ?? [''])[0] ?? '');
    }

    /** @return array<string,mixed> */
    public function importLegacy(string $legacyTable, string $actor, bool $sync = false): array
    {
        return $this->one($this->act($actor, "import-legacy table=$legacyTable sync=" . ($sync ? 'yes' : 'no')), '_ent_import_legacy', [$legacyTable, $actor, $this->dbNow(), $sync ? 'true' : 'false']);
    }

    /**
     * Invoices every due postpaid period, ONE ENTITLEMENT PER CALL (so each is its own transaction and the series counter lock is released
     * between invoices). A failure is logged with the stable token ENT_BILLING_FAILED and alerted ('entitlement.billing_failed'); the entitlement
     * backs off in the database and the run carries on with the others.
     *
     * @param ?string $asOf ISO timestamp; null = the database clock (the only value production should use)
     * @return array{invoiced:int,failed:int,entitlements:int}
     */
    public function billingRun(?string $asOf = null, int $limit = 100, string $actor = 'billing-run'): array
    {
        $due = $this->db->call('_ent_billing_due', [$asOf ?? $this->dbNow(), $limit]);
        $out = ['invoiced' => 0, 'failed' => 0, 'entitlements' => count($due)];
        foreach ($due as $d) {
            $id = (int) array_values($d)[0];
            try {
                $rows = $this->db->call('_ent_billing_run_one', [$id, $asOf ?? $this->dbNow(), $actor]);
            } catch (\Throwable $e) {
                // the call itself failed (the connection, a statement the database refused outright): this entitlement is reported and the run carries on
                $out['failed']++;
                $msg = "entitlement $id: ENT_BILLING_FAILED " . $e->getMessage();
                error_log('[payments][ENT_BILLING_FAILED] ' . $msg);
                $this->alert('entitlement.billing_failed', $id, $msg);
                continue;
            }
            foreach ($rows as $r) {
                if (($r['o_error'] ?? null) !== null) {
                    $out['failed']++;
                    $msg = "entitlement $id: " . $r['o_error'];
                    error_log('[payments][ENT_BILLING_FAILED] ' . $msg);
                    $this->alert('entitlement.billing_failed', $id, $msg);
                } elseif (($r['o_invoice_id'] ?? null) !== null) {
                    $out['invoiced']++;
                }
            }
        }

        return $out;
    }

    /**
     * Persists stale statuses in cursor batches until every row was examined.
     *
     * @return array{examined:int,changed:int}
     */
    public function tick(?string $asOf = null, int $batch = 500): array
    {
        $after = 0;
        $examined = 0;
        $changed = 0;
        for ($i = 0; $i < 100000; $i++) {                         // bounded
            $r = $this->db->call('_ent_tick', [$asOf ?? $this->dbNow(), $batch, $after])[0] ?? null;
            if ($r === null || (int) $r['o_examined'] === 0) {
                break;
            }
            $examined += (int) $r['o_examined'];
            $changed += (int) $r['o_changed'];
            $after = (int) $r['o_last_id'];
        }

        return ['examined' => $examined, 'changed' => $changed];
    }

    private function dbNow(): string
    {
        return (string) (array_values($this->db->call('_pay_db_now', [])[0] ?? [''])[0] ?? '');
    }

    private function act(string $actor, string $what): string
    {
        if (trim($actor) === '') {
            throw new \InvalidArgumentException('an actor is required for every entitlement admin action');
        }
        error_log("[payments] entitlement admin action by $actor: $what");

        return $what;
    }

    /**
     * @param array<int,mixed> $args
     * @return array<string,mixed>
     */
    private function one(string $unused, string $fn, array $args): array
    {
        return $this->db->call($fn, $args)[0] ?? [];
    }

    private function alert(string $kind, int $id, string $detail): void
    {
        if ($this->alerts === null) {
            return;
        }
        try {
            $this->alerts->alert($kind, $id, 'entitlement', (string) $id, $detail);
        } catch (\Throwable $e) {
            error_log('[payments] entitlement alert sink failed: ' . $e->getMessage());
        }
    }
}
