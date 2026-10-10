<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Orders;

use StoneScriptPay\Contracts\PaymentProvider;
use StoneScriptPay\Contracts\ServerSideCapture;
use StoneScriptPay\DTO\CreateOrderRequest;
use StoneScriptPay\Http\Webhook\SqlFunctionCaller;

/**
 * Creates payment orders idempotently.
 *
 *   1. pay_order_create (SQL) records the order under the caller's idempotency key and
 *      re-proves it (catalog item sellable, series and issuer real for the mode, the quoted
 *      amount equals the invoice the spec produces). A retry with the same key and request
 *      returns the SAME order; a different request under the same key is refused.
 *   2. Only if the order has no gateway order yet, the gateway order is created, carrying
 *      notes.order_id / notes.platform_code / notes.tenant_id so every webhook routes back to
 *      this row.
 *   3. Of several concurrent identical requests exactly ONE creates the gateway order: pay_order_begin_gateway_create is a
 *      lease; the others wait briefly for the winner's attach and are handed the same order. Before creating, the gateway
 *      is asked whether an order with our receipt already exists (a creator that crashed after the gateway call but before
 *      the attach), and PayPal's create carries a PayPal-Request-Id derived from the order reference, so even that window
 *      cannot produce a second gateway order.
 *   4. pay_order_attach_gateway_order is first-wins as a last line of defence.
 *
 * The mode (live / test) comes from the driver, i.e. from the credentials in use, never from
 * the caller.
 */
final class OrderService
{
    /**
     * @param array<string,PaymentProvider> $providers keyed by gateway code
     * @param ?CaptureApplier $capturer needed only for completeApproval() (server-side capture, e.g. PayPal)
     * @param int $waitAttempts / $waitMicros how long a request that lost the creation lease waits for the winner
     */
    public function __construct(
        private readonly SqlFunctionCaller $db,
        private readonly array $providers,
        private readonly ?CaptureApplier $capturer = null,
        private readonly int $waitAttempts = 25,
        private readonly int $waitMicros = 200000,
    ) {}

    public function create(OrderRequest $req): OrderView
    {
        $provider = $this->providers[$req->gatewayCode]
            ?? throw new \InvalidArgumentException("No payment provider configured for gateway '{$req->gatewayCode}'");
        $mode = $provider->mode();

        $rows = $this->db->call('pay_order_create', [
            $req->tenantId,
            $req->platformCode,
            $req->idempotencyKey,
            $req->purpose,
            $req->catalogRef,
            $req->invoiceId,
            $req->amountMinorUnits,
            $req->currency,
            $req->gatewayCode,
            $mode,
            $req->seriesCode,
            $req->invoiceSpec === null ? null : json_encode($req->invoiceSpec, JSON_THROW_ON_ERROR),
            $req->actor,
        ]);
        $o = $rows[0] ?? throw new \RuntimeException('pay_order_create returned no row: the order was NOT created.');

        $orderRef = (string) $o['o_order_ref'];
        $gatewayOrderId = isset($o['o_gateway_order_id']) && $o['o_gateway_order_id'] !== '' ? (string) $o['o_gateway_order_id'] : null;
        $isNew = self::bool($o['o_is_new']);
        $status = (string) $o['o_status'];

        if ($gatewayOrderId === null) {
            $lease = $this->db->call('pay_order_begin_gateway_create', [$orderRef, 30]);
            if (self::bool(array_values($lease[0] ?? [false])[0])) {
                // we are the one creator: reuse a gateway order that an earlier crashed creator already made, else create
                try {
                    $created = $provider->findOrderByReceipt($orderRef) ?? $provider->createOrder(new CreateOrderRequest(
                        amountMinorUnits: (int) $o['o_amount_minor'],
                        currency: (string) $o['o_currency'],
                        receipt: $orderRef,
                        notes: [
                            'order_id' => $orderRef,
                            'invoice_ref' => $orderRef,
                            'platform_code' => $req->platformCode,
                            'tenant_id' => $req->tenantId,
                        ],
                    ));
                } catch (\Throwable $e) {
                    try {
                        $this->db->call('pay_order_end_gateway_create', [$orderRef]);     // let the client's retry take over at once
                    } catch (\Throwable) {
                    }
                    throw $e;
                }
                $att = $this->db->call('pay_order_attach_gateway_order', [$orderRef, $created->orderId]);
                $a = $att[0] ?? throw new \RuntimeException('pay_order_attach_gateway_order returned no row.');
                $gatewayOrderId = (string) $a['o_gateway_order_id'];
                $status = (string) $a['o_status'];
            } else {
                // somebody else is creating it (or just did): wait for their attach and hand back the same order
                for ($i = 0; $i < $this->waitAttempts && $gatewayOrderId === null; $i++) {
                    $row = $this->status($orderRef, $req->tenantId, $req->platformCode);
                    if ($row !== null && isset($row['o_gateway_order_id']) && $row['o_gateway_order_id'] !== '') {
                        $gatewayOrderId = (string) $row['o_gateway_order_id'];
                        $status = (string) $row['o_status'];
                        break;
                    }
                    if ($this->waitMicros > 0) {
                        usleep($this->waitMicros);
                    }
                }
                if ($gatewayOrderId === null) {
                    throw new OrderCreationInProgressException("Order {$orderRef} is still being created by another request; retry with the same idempotency key");
                }
            }
        }

        return new OrderView(
            orderRef: $orderRef,
            gatewayCode: (string) $o['o_gateway_code'],
            gatewayOrderId: $gatewayOrderId,
            amountMinorUnits: (int) $o['o_amount_minor'],
            currency: (string) $o['o_currency'],
            mode: (string) $o['o_mode'],
            purpose: (string) $o['o_purpose'],
            status: $status,
            publishableKeyId: $provider->publishableKeyId(),
            isNew: $isNew,
        );
    }

    /**
     * The order's state for a status poll, or null when no such order belongs to this tenant and
     * platform. The webhook is what marks an order paid; the client return path only polls this.
     *
     * @return ?array<string,mixed>
     */
    public function status(string $orderRef, string $tenantId, string $platformCode): ?array
    {
        $rows = $this->db->call('pay_order_get', [$orderRef, $tenantId, $platformCode]);

        return $rows[0] ?? null;
    }

    private static function bool(mixed $v): bool
    {
        return $v === true || $v === 1 || $v === '1' || $v === 't' || $v === 'true';
    }

    /**
     * Server-side capture after the buyer approved the order (PayPal). The capture is requested with a request id derived
     * from the order reference, so retrying this call can never take the money twice; the result goes through the SAME
     * exactly-once apply path as a webhook, so it stays exactly-once with the capture webhook that follows.
     */
    public function completeApproval(string $tenantId, string $platformCode, string $orderRef): CaptureOutcome
    {
        if ($this->capturer === null) {
            throw new \LogicException('OrderService needs a CaptureApplier to complete an approval');
        }
        $row = $this->status($orderRef, $tenantId, $platformCode)
            ?? throw new PaymentNotConfirmedException("No order '{$orderRef}' for this tenant and platform");
        $gatewayCode = (string) $row['o_gateway_code'];
        $provider = $this->providers[$gatewayCode] ?? throw new \InvalidArgumentException("No payment provider configured for gateway '{$gatewayCode}'");
        if (!$provider instanceof ServerSideCapture) {
            throw new \LogicException("Gateway '{$gatewayCode}' captures inside its own checkout; there is nothing to complete server-side");
        }
        $gatewayOrderId = (string) ($row['o_gateway_order_id'] ?? '');
        if ($gatewayOrderId === '') {
            throw new PaymentNotConfirmedException("Order '{$orderRef}' has no gateway order yet");
        }

        $details = $provider->captureApprovedOrder($gatewayOrderId, $orderRef);
        if (!$details->isCaptured() || $details->amountMinorUnits !== (int) $row['o_amount_minor'] || $details->currency !== (string) $row['o_currency']) {
            throw new PaymentNotConfirmedException("The gateway's capture of order '{$orderRef}' is {$details->status} {$details->amountMinorUnits} {$details->currency}, not the order's captured {$row['o_amount_minor']} {$row['o_currency']}");
        }

        return $this->capturer->apply(new CapturePayment(
            gatewayCode: $gatewayCode,
            gatewayTxnRef: $details->paymentId,
            orderRef: $orderRef,
            tenantId: $tenantId,
            platformCode: $platformCode,
            amountMinorUnits: $details->amountMinorUnits,
            currency: $details->currency,
            mode: $provider->mode(),
            capturedAt: $details->capturedAt ?? new \DateTimeImmutable(),
            source: 'server-capture:' . $gatewayCode . ($details->capturedAt === null || $details->capturedAtIsEstimate ? ':capture-time-estimated' : ''),
            rawJson: RawPayloadAllowlist::forPayment($details->raw, hash('sha256', (string) json_encode($details->raw, JSON_INVALID_UTF8_SUBSTITUTE))),
        ));
    }
}
