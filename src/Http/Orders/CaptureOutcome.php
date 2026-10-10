<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Orders;

/** What pay_apply_capture did: applied, already_applied (a redelivery), unattributed (no such order), refund_required or captured_not_applied. */
final class CaptureOutcome
{
    public const APPLIED = 'applied';
    public const ALREADY_APPLIED = 'already_applied';
    public const UNATTRIBUTED = 'unattributed';
    /** money arrived that nothing could fulfil: rolled back, in pay_refund_queue */
    public const REFUND_REQUIRED = 'refund_required';
    /** the capture is recorded but its order never took effect: NOT a replay of a success */
    public const CAPTURED_NOT_APPLIED = 'captured_not_applied';

    public function __construct(
        public readonly string $outcome,
        public readonly ?string $orderRef,
        public readonly ?string $purpose,
        public readonly ?int $invoiceId,
        public readonly ?int $paymentId,
        public readonly ?string $detail,
    ) {}
}
