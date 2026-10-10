<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

/** What the webhook endpoint answers: an HTTP status and the standard {status,message,data} body. */
final class IngressResult
{
    /** @param array<string,mixed> $data */
    public function __construct(
        public readonly int $httpStatus,
        public readonly string $message,
        public readonly array $data = [],
    ) {}

    public function isOk(): bool
    {
        return $this->httpStatus >= 200 && $this->httpStatus < 300;
    }
}
