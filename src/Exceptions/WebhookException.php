<?php

declare(strict_types=1);

namespace StoneScriptPay\Exceptions;

/**
 * Raised when a webhook payload cannot be parsed or has a missing/unknown event.
 *
 * Distinct from SignatureVerificationException (which fires on HMAC mismatch).
 * WebhookException covers structural problems with the payload itself.
 *
 * @package StoneScriptPay\Exceptions
 */
class WebhookException extends PaymentException
{
    public function __construct(string $reason)
    {
        parent::__construct("Webhook processing failed: {$reason}");
    }
}
