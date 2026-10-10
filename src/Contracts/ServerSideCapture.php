<?php

declare(strict_types=1);

namespace StoneScriptPay\Contracts;

use StoneScriptPay\DTO\PaymentDetails;
use StoneScriptPay\Exceptions\PaymentException;

/**
 * Implemented by gateways whose order is NOT captured by the hosted checkout itself: the buyer approves the order, and the
 * merchant's server must then capture it (PayPal Orders v2). Razorpay captures inside its checkout and does not need this.
 *
 * Capturing is idempotent for the same $requestId: the gateway returns the original capture instead of taking the money a
 * second time (PayPal-Request-Id). The caller derives the request id from the order reference, so a retried capture call
 * can never double-charge.
 */
interface ServerSideCapture
{
    /**
     * Capture an approved order and return the resulting payment, normalised (status 'captured' when the money moved).
     *
     * @throws PaymentException if the order is not approved, is already captured by a different request, or the call fails.
     */
    public function captureApprovedOrder(string $gatewayOrderId, string $requestId): PaymentDetails;
}
