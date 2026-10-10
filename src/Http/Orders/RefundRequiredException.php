<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Orders;

use StoneScriptPay\Exceptions\PaymentException;

/**
 * Money arrived at the gateway that the library could not apply (order already paid or cancelled, invoice voided or already
 * paid). Nothing was fulfilled and the case sits in pay_refund_queue. Thrown by the webhook processor so the inbox row fails
 * and alerts; a human refunds (or applies) it and closes the queue entry with _pay_refund_queue_resolve().
 */
final class RefundRequiredException extends PaymentException {}
