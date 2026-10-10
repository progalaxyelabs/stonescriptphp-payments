<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Entitlement;

/**
 * Runs a database call against the MAIN (platform-wide) database, whatever tenant context the request is in.
 *
 * The entitlement store lives in the main database. A request that already selected a tenant schema would otherwise send ent_get to the
 * tenant database, where it does not exist. Implementations clear the tenant context for the duration of the call and ALWAYS restore it
 * afterwards (also when the call throws). FrameworkMainDbScope does this for the StoneScriptPHP gateway client, exactly as the framework's own
 * subscription middleware does for its status lookup.
 */
interface MainDbScope
{
    /**
     * @template T
     * @param callable():T $fn
     * @return T
     */
    public function run(callable $fn): mixed;
}
