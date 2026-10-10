<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Entitlement;

/** The outcome of EntitlementGuard::decide(): let the request through (with a state header), or refuse it with 423 and a body. */
final class GuardDecision
{
    /** @param array<string,mixed> $data */
    private function __construct(
        public readonly bool $allowed,
        public readonly string $stateHeader,
        public readonly int $httpStatus,
        public readonly string $message,
        public readonly array $data,
    ) {}

    public static function allow(string $stateHeader): self
    {
        return new self(true, $stateHeader, 200, '', []);
    }

    /** @param array<string,mixed> $data */
    public static function refuse(string $stateHeader, array $data, string $message): self
    {
        return new self(false, $stateHeader, 423, $message, $data);
    }
}
