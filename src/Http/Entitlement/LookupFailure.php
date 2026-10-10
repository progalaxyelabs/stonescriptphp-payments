<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Entitlement;

/**
 * Classifies why an entitlement lookup failed, because the right response differs:
 *   TRANSPORT  the database / gateway could not be reached in time (connection, timeout, resource exhaustion): infrastructure trouble. The
 *              middleware fails OPEN (or serves the last-known decision), and alerts only if it persists.
 *   DEPLOY     the lookup reached the database and it is the DEPLOYMENT that is wrong: ent_get missing (undefined function / table), a required
 *              pay_config row missing (PY050), a column missing, or an empty result where ent_get always answers. A bug to fix, not a blip: logged
 *              at error level with a stable token and alerted at once, while the request is still served.
 *   UNKNOWN    anything else: treated like TRANSPORT for serving, logged at error level too.
 */
final class LookupFailure
{
    public const TRANSPORT = 'transport';
    public const DEPLOY = 'deploy';
    public const UNKNOWN = 'unknown';

    private const DEPLOY_STATES = ['PY050', '42883', '42P01', '42703', '42P02', '3F000'];

    public static function classify(\Throwable $e): string
    {
        $state = '';
        if ($e instanceof \PDOException && is_array($e->errorInfo ?? null) && isset($e->errorInfo[0])) {
            $state = (string) $e->errorInfo[0];
        }
        $code = $state !== '' ? $state : (string) $e->getCode();
        $msg = $e->getMessage();
        if (in_array($code, self::DEPLOY_STATES, true) || preg_match('/PY050|undefined function|does not exist|undefined table|undefined column|no function matches/i', $msg) === 1) {
            return self::DEPLOY;
        }
        if (preg_match('/^(08|53|57)/', $code) === 1
            || preg_match('/timeout|timed out|connection|could not connect|unavailable|refused|reset by peer|broken pipe|too many connections|SQLSTATE\[08|statement timeout/i', $msg) === 1
            || $e instanceof \RuntimeException && $code === '0') {
            return self::TRANSPORT;
        }

        return self::UNKNOWN;
    }
}
