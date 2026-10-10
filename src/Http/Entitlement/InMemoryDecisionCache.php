<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Entitlement;

/** DecisionCache in process memory (static, so it survives across the requests one worker serves). Bounded to $maxEntries (oldest dropped). */
final class InMemoryDecisionCache implements DecisionCache
{
    /** @var array<string,array{0:int,1:array<string,mixed>}> */
    private static array $rows = [];
    private static int $failures = 0;
    /** @var array<string,int> */
    private static array $alerted = [];

    public function __construct(private readonly int $ttlSeconds = 600, private readonly int $maxEntries = 5000) {}

    public static function reset(): void
    {
        self::$rows = [];
        self::$failures = 0;
        self::$alerted = [];
    }

    public function put(string $key, array $row, int $now): void
    {
        self::$rows[$key] = [$now, $row];
        if (count(self::$rows) > $this->maxEntries) {
            uasort(self::$rows, static fn (array $a, array $b): int => $a[0] <=> $b[0]);
            self::$rows = array_slice(self::$rows, (int) (count(self::$rows) / 2), null, true);
        }
    }

    public function get(string $key, int $now): ?array
    {
        $e = self::$rows[$key] ?? null;

        return $e !== null && $now - $e[0] <= $this->ttlSeconds ? $e[1] : null;
    }

    public function recordFailure(): int
    {
        return ++self::$failures;
    }

    public function recordSuccess(): void
    {
        self::$failures = 0;
    }

    public function claimAlertSlot(string $kind, int $now, int $minGapSeconds): bool
    {
        if (isset(self::$alerted[$kind]) && $now - self::$alerted[$kind] < $minGapSeconds) {
            return false;
        }
        self::$alerted[$kind] = $now;

        return true;
    }
}
