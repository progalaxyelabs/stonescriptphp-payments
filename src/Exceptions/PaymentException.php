<?php

declare(strict_types=1);

namespace StoneScriptPay\Exceptions;

/**
 * Base exception for all payment errors raised by stonescriptphp-payments drivers.
 *
 * Wraps provider-level errors (network failures, API errors) so consuming code
 * can catch a single type without coupling to provider-specific exception classes.
 *
 * @package StoneScriptPay\Exceptions
 */
class PaymentException extends \RuntimeException
{
    public function __construct(
        string $message,
        int $code = 0,
        ?\Throwable $previous = null,
    ) {
        parent::__construct($message, $code, $previous);
    }
}
