<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

/**
 * The one seam between the HTTP module and the database: call a SQL function by name with
 * positional arguments and get its rows back as associative arrays.
 *
 * In a StoneScriptPHP application the shipped DatabaseFnCaller binds this to
 * StoneScriptPHP\Database::fn() (the gateway). The module has no other database dependency.
 */
interface SqlFunctionCaller
{
    /**
     * @param list<mixed> $args Positional arguments (null, bool, int, float, string).
     * @return list<array<string,mixed>> Result rows ([] for a function that returns no rows).
     * @throws \Throwable on any database or transport error.
     */
    public function call(string $function, array $args): array;
}
