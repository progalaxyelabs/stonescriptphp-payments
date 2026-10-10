<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Orders;

use StoneScriptPay\Exceptions\PaymentException;

/** A capture is recorded for an order that is not paid: a half-applied state that must be looked at by a human. */
final class CapturedNotAppliedException extends PaymentException {}
