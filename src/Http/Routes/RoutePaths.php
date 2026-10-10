<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Routes;

/**
 * Where the library's own HTTP routes are mounted: ONE namespaced prefix, '/pay' by default, with the orders, payments, quote and webhook routes
 * underneath. A platform registers them with these paths (and may choose another prefix); the entitlement write allow-list follows the same prefix
 * (EntitlementGuard), so a read-only tenant can always pay and no generic path like /orders is write-allowed on the library's behalf.
 *
 *   {prefix}/orders            create an order            {prefix}/orders/{ref}   poll it
 *   {prefix}/payments          admin / verify paths       {prefix}/quote          price breakdown (pay_order_quote)
 *   {prefix}/webhook/{gateway} the gateway webhook (PostWebhookRoute)
 */
final class RoutePaths
{
    public const DEFAULT_PREFIX = '/pay';

    public static function normalisePrefix(string $prefix): string
    {
        $p = '/' . trim($prefix, '/');
        if ($p === '/' || preg_match('#^/[A-Za-z0-9._~/-]+$#', $p) !== 1 || str_contains($p, '..')) {
            throw new \InvalidArgumentException('the library route prefix must be a plain path such as /pay');
        }

        return $p;
    }

    public static function webhook(string $prefix = self::DEFAULT_PREFIX): string
    {
        return self::normalisePrefix($prefix) . '/webhook/{gateway}';
    }

    public static function orders(string $prefix = self::DEFAULT_PREFIX): string
    {
        return self::normalisePrefix($prefix) . '/orders';
    }

    public static function payments(string $prefix = self::DEFAULT_PREFIX): string
    {
        return self::normalisePrefix($prefix) . '/payments';
    }

    public static function quote(string $prefix = self::DEFAULT_PREFIX): string
    {
        return self::normalisePrefix($prefix) . '/quote';
    }
}
