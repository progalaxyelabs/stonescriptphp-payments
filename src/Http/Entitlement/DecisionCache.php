<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Entitlement;

/**
 * Remembers the last GOOD entitlement row per tenant and the count of consecutive lookup failures, so a database blip does not flip a lapsed
 * tenant to writable (the last-known decision is used for up to $ttlSeconds) and a persistent failure is noticed. The default is process
 * memory (shared across the requests one PHP worker serves); a platform running several workers that wants one shared view implements this
 * over APCu or Redis.
 */
interface DecisionCache
{
    /** @param array<string,mixed> $row */
    public function put(string $key, array $row, int $now): void;

    /** @return ?array<string,mixed> the last good row for the key if it is younger than the TTL */
    public function get(string $key, int $now): ?array;

    /** @return int the number of consecutive failures including this one */
    public function recordFailure(): int;

    public function recordSuccess(): void;

    /**
     * Claims the right to raise an alert of this kind now: true at most once per $minGapSeconds across everything sharing this cache (every request
     * the worker serves), so a bad deploy alerts once per window, not once per request.
     */
    public function claimAlertSlot(string $kind, int $now, int $minGapSeconds): bool;
}
