<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Entitlement;

use StoneScriptPay\Http\Routes\RoutePaths;

/**
 * The access decision for one request, from the entitlement row ent_get() returned. Pure PHP (no framework, no database), so
 * every platform enforces the same rules and the rules are testable without a server. EntitlementMiddleware is the framework adapter.
 *
 * Behaviour is the framework Subscriptions middleware's, reading the one entitlement store instead of the legacy table:
 *   - exempt paths pass untouched (health, auth);
 *   - a tenant that may write passes; the response carries an informational X-Subscription-State;
 *   - a read-only tenant may still READ (GET / HEAD / OPTIONS) and may WRITE only to the allow-listed paths (renewal and payment,
 *     export, data-erasure and account recovery) - everything else is refused with HTTP 423 and the error code from ent_get
 *     (READ_ONLY_TRIAL_EXPIRED | READ_ONLY_PLAN_ENDED | READ_ONLY_PAYMENT_OVERDUE | READ_ONLY_NO_SUBSCRIPTION).
 */
final class EntitlementGuard
{
    public const HEADER_NAME = 'X-Subscription-State';

    public const DEFAULT_WRITE_ALLOW_LIST = [
        '/health', '/auth', '/subscription', '/export', '/internal', '/account/subscription',
        // the library's own money routes all live under ONE namespaced prefix (RoutePaths::DEFAULT_PREFIX = '/pay'): orders, payments, quote, webhook.
        // A read-only tenant must ALWAYS be able to pay, so that prefix is write-allowed; a platform that mounts them elsewhere passes its prefix
        // to the constructor and the allow-list follows it (no generic /orders or /payments entry exists to be matched by a platform's own routes)
        '/pay',
        'DELETE /account', 'POST /account/delete', 'POST /account/cancel-deletion', 'POST /account/password', 'POST /account/password-reset/',
    ];
    public const DEFAULT_EXEMPT = ['/health', '/auth/'];

    /** @var list<string> */
    private array $writeAllowList;
    /** @var list<string> */
    private array $exempt;

    /**
     * @param list<string> $writeAllowList extra write-allowed paths (added to the defaults); "METHOD /path" scopes one method; a trailing
     *                                     slash is a prefix; /path matches the path and everything under it
     * @param list<string>|null $exempt     paths that are never checked (default: /health and /auth/)
     * @param string $libraryPrefix         where the library's own routes are mounted (default '/pay'); that prefix, and only that, is write-allowed
     */
    public function __construct(array $writeAllowList = [], ?array $exempt = null, private readonly int $warningDays = 7, string $libraryPrefix = RoutePaths::DEFAULT_PREFIX)
    {
        $defaults = array_values(array_filter(self::DEFAULT_WRITE_ALLOW_LIST, static fn (string $e): bool => $e !== '/pay'));
        $defaults[] = RoutePaths::normalisePrefix($libraryPrefix);
        $this->writeAllowList = array_values(array_unique(array_merge($defaults, $writeAllowList)));
        $this->exempt = $exempt ?? self::DEFAULT_EXEMPT;
    }

    public function isExempt(string $path): bool
    {
        return $this->matchesAny($path, $this->exempt, true);
    }

    /**
     * @param ?array<string,mixed> $row one row of ent_get(); null = the lookup failed (the guard then fails OPEN: infrastructure
     *                                  trouble must not lock customers out)
     */
    public function decide(string $method, string $path, ?array $row): GuardDecision
    {
        if ($row === null) {
            return GuardDecision::allow('ok');
        }
        $readOnly = self::truthy($row['o_read_only'] ?? false);
        $status = (string) ($row['o_status'] ?? 'none');
        $header = $this->header($row, $status, $readOnly);
        if (!$readOnly) {
            return GuardDecision::allow($header);
        }
        $method = strtoupper($method);
        if (in_array($method, ['GET', 'HEAD', 'OPTIONS'], true) || $this->isWriteAllowed($method, $path)) {
            return GuardDecision::allow($header);
        }

        return GuardDecision::refuse($header, [
            'error_code' => (string) ($row['o_error_code'] ?? 'READ_ONLY_PLAN_ENDED'),
            'subscription_state' => 'read_only',
            'reason' => $row['o_reason'] ?? null,
            'status' => $status,
            'is_trial' => self::truthy($row['o_is_trial'] ?? false),
            'ended_at' => self::iso($row['o_period_end'] ?? null),
            'overdue_since' => self::iso($row['o_overdue_since'] ?? null),
        ], 'This account is read-only. You can still view your data; renew or settle the outstanding invoice to continue.');
    }

    /** @param array<string,mixed> $row */
    private function header(array $row, string $status, bool $readOnly): string
    {
        if ($readOnly) {
            $parts = ['read_only'];
            if (($end = self::iso($row['o_period_end'] ?? null)) !== null) {
                $parts[] = 'ended_at=' . $end;
            }
            if (($row['o_reason'] ?? null) !== null) {
                $parts[] = 'reason=' . $row['o_reason'];
            }

            return implode('; ', $parts);
        }
        if ($status === 'past_due') {
            return 'past_due; reason=payment_overdue';
        }
        $days = isset($row['o_days_remaining']) && $row['o_days_remaining'] !== null ? (int) $row['o_days_remaining'] : null;
        if ($days !== null && $days <= max(0, $this->warningDays)) {
            $kind = self::truthy($row['o_is_trial'] ?? false) ? 'trial_ending' : 'plan_ending';

            return $kind . '; ends_at=' . (self::iso($row['o_period_end'] ?? null) ?? '') . '; days=' . $days;
        }

        return 'ok';
    }

    private static function truthy(mixed $v): bool
    {
        return $v === true || $v === 't' || $v === 'true' || $v === 1 || $v === '1';
    }

    private static function iso(mixed $v): ?string
    {
        if (!is_string($v) || trim($v) === '') {
            return null;
        }
        try {
            return (new \DateTimeImmutable($v))->setTimezone(new \DateTimeZone('UTC'))->format('Y-m-d\TH:i:s\Z');
        } catch (\Exception) {
            return null;
        }
    }

    private function isWriteAllowed(string $method, string $path): bool
    {
        foreach ($this->writeAllowList as $entry) {
            $entry = trim($entry);
            $scoped = false;
            if (preg_match('/^([A-Za-z]+)\s+(\/.*)$/', $entry, $m) === 1) {
                if (strtoupper($m[1]) !== $method) {
                    continue;
                }
                $entry = $m[2];
                $scoped = true;
            }
            if ($this->matchesAny($path, [$entry], !$scoped)) {
                return true;
            }
        }

        return false;
    }

    /** @param list<string> $entries */
    private function matchesAny(string $path, array $entries, bool $componentPrefix): bool
    {
        // fail closed on traversal / encoded-separator tricks: such a path can reach a different route than the entry names
        if (preg_match('/%2e|%2f|%5c/i', $path) === 1 || str_contains($path, '\\')) {
            return false;
        }
        foreach (explode('/', $path) as $segment) {
            if ($segment === '.' || $segment === '..') {
                return false;
            }
        }
        $candidates = [$path];
        $stripped = preg_replace('#^/api(?=/|$)#', '', $path);
        if ($stripped !== null && $stripped !== $path) {
            $candidates[] = $stripped === '' ? '/' : $stripped;
        }
        foreach ($entries as $entry) {
            $prefix = str_ends_with($entry, '/');
            $base = $prefix ? rtrim($entry, '/') : $entry;
            $regex = '#^' . implode('', array_map(
                static fn (string $part): string => preg_match('/^\{[A-Za-z_][A-Za-z0-9_]*\}$/', $part) === 1 ? '[^/]+' : preg_quote($part, '#'),
                preg_split('/(\{[A-Za-z_][A-Za-z0-9_]*\})/', $base, -1, PREG_SPLIT_DELIM_CAPTURE | PREG_SPLIT_NO_EMPTY) ?: [],
            )) . (($prefix || $componentPrefix) ? '(?:/.*)?' : '') . '$#';
            foreach ($candidates as $p) {
                if (preg_match($regex, $p) === 1) {
                    return true;
                }
            }
        }

        return false;
    }
}
