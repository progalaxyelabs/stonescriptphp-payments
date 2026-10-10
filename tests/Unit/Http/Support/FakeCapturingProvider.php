<?php

declare(strict_types=1);

namespace Tests\Http\Support;

use StoneScriptPay\Contracts\ServerSideCapture;
use StoneScriptPay\DTO\PaymentDetails;
use StoneScriptPay\Exceptions\PaymentException;

/** A FakeProvider whose orders are captured by the server after approval (PayPal-style). */
final class FakeCapturingProvider extends FakeProvider implements ServerSideCapture
{
    /** @var list<array{string,string}> [gatewayOrderId, requestId] */
    public array $captureCalls = [];
    public bool $approved = true;
    public int $amount = 0;
    public string $currency = 'INR';

    public function captureApprovedOrder(string $gatewayOrderId, string $requestId): PaymentDetails
    {
        $this->captureCalls[] = [$gatewayOrderId, $requestId];
        if (!$this->approved) {
            throw new PaymentException('order not approved');
        }

        // idempotent per request id, like PayPal-Request-Id: the same request always yields the same capture
        return new PaymentDetails('CAP_' . substr(hash('sha256', $requestId), 0, 12), 'captured', $this->amount, $this->currency, $gatewayOrderId,
            new \DateTimeImmutable('2026-10-10T10:00:00+05:30'), [], ['id' => 'x', 'payer' => ['email_address' => 'payer@example.test']]);
    }
}
