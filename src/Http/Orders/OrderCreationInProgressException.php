<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Orders;

use StoneScriptPay\Exceptions\PaymentException;

/** Another request holds the lease to create this order's gateway order and has not finished: retry with the same key. */
final class OrderCreationInProgressException extends PaymentException {}
