<?php

declare(strict_types=1);

namespace StoneScriptPay\Exceptions;

/**
 * A webhook whose signature was VERIFIED but whose body cannot be read (for example not
 * valid JSON).
 *
 * A driver throws this ONLY after signature verification has succeeded, so the caller can
 * rely on it: the event is authentic and must be stored raw (never dropped), unlike a plain
 * WebhookException, which can also mean "webhook secret not configured" or "unverifiable".
 *
 * @package StoneScriptPay\Exceptions
 */
class MalformedWebhookException extends WebhookException
{
    /**
     * @param ?string $eventId The gateway's event id, when it travels in a header and so is
     *                         known even though the body is unreadable (Razorpay does this).
     */
    public function __construct(string $message, public readonly ?string $eventId = null)
    {
        parent::__construct($message);
    }
}
