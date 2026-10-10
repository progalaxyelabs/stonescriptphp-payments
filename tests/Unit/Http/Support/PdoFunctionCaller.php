<?php

declare(strict_types=1);

namespace Tests\Http\Support;

/**
 * SqlFunctionCaller over PDO/pgsql, for tests that run the real SQL functions. It sends every
 * argument as text and lets Postgres coerce it to the function's parameter type, the way the
 * gateway does. Optionally fails the next N calls (an unavailable database).
 */
final class PdoFunctionCaller extends FailableCaller
{
    public function __construct(private readonly \PDO $pdo) {}

    public function call(string $function, array $args): array
    {
        $this->maybeFail();
        $marks = implode(', ', array_fill(0, count($args), '?'));
        $stmt = $this->pdo->prepare("SELECT * FROM {$function}({$marks})");
        foreach (array_values($args) as $i => $v) {
            if ($v === null) {
                $stmt->bindValue($i + 1, null, \PDO::PARAM_NULL);
            } elseif (is_bool($v)) {
                $stmt->bindValue($i + 1, $v ? 'true' : 'false');
            } else {
                $stmt->bindValue($i + 1, (string) $v);
            }
        }
        $stmt->execute();

        return $stmt->fetchAll(\PDO::FETCH_ASSOC);
    }
}
