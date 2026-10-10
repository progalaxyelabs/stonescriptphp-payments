<?php

declare(strict_types=1);

namespace Tests\Http\Support;

use StoneScriptPay\Contracts\PaymentProvider;
use StoneScriptPay\DTO\CreateOrderRequest;
use StoneScriptPay\DTO\CreateSubscriptionRequest;
use StoneScriptPay\DTO\OrderResult;
use StoneScriptPay\DTO\PaymentDetails;
use StoneScriptPay\DTO\RefundRequest;
use StoneScriptPay\DTO\RefundResult;
use StoneScriptPay\DTO\SubscriptionResult;
use StoneScriptPay\DTO\VerificationResult;
use StoneScriptPay\DTO\VerifyRequest;
use StoneScriptPay\DTO\WebhookEvent;
use StoneScriptPay\DTO\WebhookRequest;
use StoneScriptPay\Exceptions\PaymentException;

/** A scriptable gateway for order and operator-path tests. */
class FakeProvider implements PaymentProvider
{
    /** @var list<CreateOrderRequest> */
    public array $createdOrders = [];
    /** @var array<string,PaymentDetails> */
    public array $payments = [];
    public int $failCreateTimes = 0;
    /** @var array<string,OrderResult> orders that already exist at the gateway, by receipt */
    public array $existingByReceipt = [];
    public int $findCalls = 0;
    private int $seq = 0;

    public function __construct(public string $mode = 'test', public string $keyId = 'rzp_test_fake') {}

    public function createOrder(CreateOrderRequest $req): OrderResult
    {
        if ($this->failCreateTimes > 0) {
            $this->failCreateTimes--;
            throw new PaymentException('gateway unavailable');
        }
        $this->createdOrders[] = $req;
        $id = 'order_fake_' . bin2hex(random_bytes(6)) . '_' . (++$this->seq);   // random: the database outlives a test

        return new OrderResult($id, $req->amountMinorUnits, $req->currency, $req->receipt, $this->keyId, 'created', []);
    }

    public function findOrderByReceipt(string $receipt): ?OrderResult
    {
        $this->findCalls++;

        return $this->existingByReceipt[$receipt] ?? null;
    }

    public function webhookSignatureHeader(): string
    {
        return 'x-fake-signature';
    }

    public function mode(): string
    {
        return $this->mode;
    }

    public function publishableKeyId(): string
    {
        return $this->keyId;
    }

    public function fetchPayment(string $paymentId): PaymentDetails
    {
        return $this->payments[$paymentId] ?? throw new PaymentException("No such payment '{$paymentId}'");
    }

    public function verifySignature(VerifyRequest $req): VerificationResult
    {
        throw new \LogicException('not used');
    }

    public function handleWebhook(WebhookRequest $req): WebhookEvent
    {
        throw new \LogicException('not used');
    }

    public function createSubscription(CreateSubscriptionRequest $req): SubscriptionResult
    {
        throw new \LogicException('not used');
    }

    public function cancelSubscription(string $subscriptionId): SubscriptionResult
    {
        throw new \LogicException('not used');
    }

    public function getSubscription(string $subscriptionId): SubscriptionResult
    {
        throw new \LogicException('not used');
    }

    public function refund(RefundRequest $req): RefundResult
    {
        throw new \LogicException('not used');
    }

    public function settlementModel(): string
    {
        return 'gateway';
    }
}
