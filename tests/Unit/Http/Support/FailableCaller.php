<?php

declare(strict_types=1);

namespace Tests\Http\Support;

use StoneScriptPay\Http\Webhook\SqlFunctionCaller;

/** A SqlFunctionCaller that can be told to fail its next N calls (an unavailable database / gateway). */
abstract class FailableCaller implements SqlFunctionCaller
{
    public int $failTimes = 0;

    final protected function maybeFail(): void
    {
        if ($this->failTimes > 0) {
            $this->failTimes--;
            throw new \RuntimeException('database unavailable (simulated)');
        }
    }

    /**
     * The caller the real-SQL tests use: through a StoneScriptDB Gateway when PAYMENTS_TEST_GATEWAY_URL (+ _PLATFORM, _SCHEMA)
     * is set, otherwise straight over PDO. Same tests, two transports.
     */
    public static function forTests(\PDO $pdo): self
    {
        $url = getenv('PAYMENTS_TEST_GATEWAY_URL');
        if ($url !== false && $url !== '') {
            return new GatewayHttpCaller($url, (string) getenv('PAYMENTS_TEST_GATEWAY_PLATFORM'), (string) (getenv('PAYMENTS_TEST_GATEWAY_SCHEMA') ?: 'main'));
        }

        return new PdoFunctionCaller($pdo);
    }
}
