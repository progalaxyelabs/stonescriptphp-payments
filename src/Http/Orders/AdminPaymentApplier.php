<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Orders;

use StoneScriptPay\Contracts\PaymentProvider;
use StoneScriptPay\Http\Webhook\SqlFunctionCaller;

/**
 * Applies a payment on an operator's say-so, but only after the GATEWAY confirms it.
 *
 * An operator pastes a payment id (a webhook never arrived, or arrived unattributed). Before
 * anything is applied, the gateway is asked what happened to that payment, with our own
 * credentials (PaymentProvider::fetchPayment), and it must be:
 *   - captured (not merely authorized, failed or refunded);
 *   - for exactly the order's amount and currency;
 *   - against the order's own gateway order (so a real payment for something else cannot be
 *     pinned on this order).
 * Otherwise PaymentNotConfirmedException is thrown and nothing is written. When confirmed it goes
 * through the same CaptureApplier as a webhook, so it is exactly-once with a webhook that arrives
 * later (that one becomes already_applied).
 *
 * AUTHORISATION IS THE PLATFORM'S: $actor must be the authenticated operator's id taken from the platform's own session /
 * token, never a value the operator types or the client sends - it is written to pay_captured_payments.created_by as the
 * audit trail ('admin:<actor>').
 *
 * A PARTLY REFUNDED payment (still 'captured' at the gateway, with amount_refunded > 0) is refused unless the caller says
 * explicitly $allowPartiallyRefunded: applying it would fulfil a full order for money that is already partly given back.
 * The capture time recorded is the gateway's; when the gateway reports only the payment's creation time that is used and
 * flagged in the audit source ('capture-time-estimated').
 */
final class AdminPaymentApplier
{
    /** @param array<string,PaymentProvider> $providers keyed by gateway code */
    public function __construct(
        private readonly SqlFunctionCaller $db,
        private readonly CaptureApplier $applier,
        private readonly array $providers,
    ) {}

    public function apply(string $tenantId, string $platformCode, string $orderRef, string $gatewayCode, string $paymentId, string $actor, bool $allowPartiallyRefunded = false): CaptureOutcome
    {
        if (trim($actor) === '') {
            throw new \InvalidArgumentException('An operator name is required to apply a payment by hand.');
        }
        $provider = $this->providers[$gatewayCode]
            ?? throw new \InvalidArgumentException("No payment provider configured for gateway '{$gatewayCode}'");

        $rows = $this->db->call('pay_order_get', [$orderRef, $tenantId, $platformCode]);
        $order = $rows[0] ?? throw new PaymentNotConfirmedException("No order '{$orderRef}' for this tenant and platform");
        if ((string) $order['o_gateway_code'] !== $gatewayCode) {
            throw new PaymentNotConfirmedException("Order '{$orderRef}' is a {$order['o_gateway_code']} order, not {$gatewayCode}");
        }

        $details = $provider->fetchPayment($paymentId);     // throws PaymentException if the gateway cannot confirm it exists

        if (!$details->isCaptured()) {
            throw new PaymentNotConfirmedException("The gateway reports payment {$paymentId} as '{$details->status}', not captured");
        }
        if ($details->amountMinorUnits !== (int) $order['o_amount_minor'] || $details->currency !== (string) $order['o_currency']) {
            throw new PaymentNotConfirmedException(
                "The gateway reports payment {$paymentId} as {$details->amountMinorUnits} {$details->currency}; the order is for {$order['o_amount_minor']} {$order['o_currency']}"
            );
        }
        $orderGateway = $order['o_gateway_order_id'] ?? null;
        if ($orderGateway === null || $orderGateway === '' || $details->gatewayOrderId !== (string) $orderGateway) {
            throw new PaymentNotConfirmedException("Payment {$paymentId} does not belong to this order's gateway order");
        }
        if ($details->isPartlyRefunded() && !$allowPartiallyRefunded) {
            throw new PaymentNotConfirmedException(
                "Payment {$paymentId} has already been partly refunded ({$details->amountRefundedMinorUnits} of {$details->amountMinorUnits}); refusing to fulfil the order for it"
            );
        }
        if ($details->capturedAt === null) {
            throw new PaymentNotConfirmedException("The gateway did not report when payment {$paymentId} was captured");
        }

        return $this->applier->apply(new CapturePayment(
            gatewayCode: $gatewayCode,
            gatewayTxnRef: $details->paymentId,
            orderRef: $orderRef,
            tenantId: $tenantId,
            platformCode: $platformCode,
            amountMinorUnits: $details->amountMinorUnits,
            currency: $details->currency,
            mode: $provider->mode(),
            capturedAt: $details->capturedAt,
            source: 'admin:' . $actor . ($details->capturedAtIsEstimate ? ':capture-time-estimated' : ''),
            rawJson: RawPayloadAllowlist::forPayment($details->raw, hash('sha256', (string) json_encode($details->raw, JSON_INVALID_UTF8_SUBSTITUTE))),
        ));
    }
}
