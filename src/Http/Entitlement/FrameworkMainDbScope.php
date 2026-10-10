<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Entitlement;

use StoneScriptPHP\Database;

/** MainDbScope over the StoneScriptPHP gateway client: tenant context cleared for the call, restored in `finally`. Requires the framework. */
final class FrameworkMainDbScope implements MainDbScope
{
    public function run(callable $fn): mixed
    {
        $gw = Database::getGatewayClient();
        $previous = $gw->getTenantId();
        $gw->setTenantId(null);                 // always the main database
        try {
            return $fn();
        } finally {
            $gw->setTenantId($previous);
        }
    }
}
