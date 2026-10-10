<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

/**
 * SqlFunctionCaller over StoneScriptPHP\Database::fn() (the StoneScriptDB Gateway). Requires the framework >= 12.0.
 *
 * Reads and the library's own functions go through Database::fn(): they signal failure by RAISING (a SQLSTATE the PHP side classifies), never by an
 * empty result. A platform that runs the framework's persistence contract (PERSISTENCE_CONTRACT=enforced) and wants the write boundary on specific
 * functions can name them in $mutations: those calls then go through Database::mutate() and a failure surfaces as the framework's typed
 * PersistenceException. The map is function name => allowEmpty (true when zero rows is a legitimate no-op, as for a claim that finds nothing).
 * It is off by default: a PersistenceException replaces the PDOException/SQLSTATE the library's own callers inspect.
 *
 * The framework is a soft dependency: this class is only instantiated by an application that
 * has it installed; constructing it without the framework fails loudly rather than at the
 * first webhook.
 */
final class DatabaseFnCaller implements SqlFunctionCaller
{
    /** @param array<string,bool> $mutations function name => allowEmpty, routed through Database::mutate() */
    public function __construct(private readonly array $mutations = [])
    {
        if (!class_exists(\StoneScriptPHP\Database::class)) {
            throw new \LogicException(
                'DatabaseFnCaller needs progalaxyelabs/stonescriptphp (StoneScriptPHP\\Database). '
                . 'Install it, or implement SqlFunctionCaller over your own database layer.'
            );
        }
    }

    public function call(string $function, array $args): array
    {
        $rows = array_key_exists($function, $this->mutations)
            ? \StoneScriptPHP\Database::mutate($function, $args, allowEmpty: $this->mutations[$function])
            : \StoneScriptPHP\Database::fn($function, $args);
        return is_array($rows) ? array_values($rows) : [];
    }
}
