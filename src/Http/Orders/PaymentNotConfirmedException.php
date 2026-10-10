<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Orders;

use StoneScriptPay\Exceptions\PaymentException;

/** The gateway did not confirm a payment as captured for the order's amount: nothing was applied. */
final class PaymentNotConfirmedException extends PaymentException {}
