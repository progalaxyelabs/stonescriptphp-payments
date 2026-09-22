<?php

declare(strict_types=1);

namespace StoneScriptPay\Contracts;

use StoneScriptPay\DTO\CreateOrderRequest;
use StoneScriptPay\DTO\CreateSubscriptionRequest;
use StoneScriptPay\DTO\OrderResult;
use StoneScriptPay\DTO\RefundRequest;
use StoneScriptPay\DTO\RefundResult;
use StoneScriptPay\DTO\SubscriptionResult;
use StoneScriptPay\DTO\VerificationResult;
use StoneScriptPay\DTO\VerifyRequest;
use StoneScriptPay\DTO\WebhookEvent;
use StoneScriptPay\DTO\WebhookRequest;
use StoneScriptPay\Exceptions\PaymentException;
use StoneScriptPay\Exceptions\SignatureVerificationException;
use StoneScriptPay\Exceptions\WebhookException;

/**
 * Payment provider abstraction.
 *
 * Every driver (Razorpay, Paddle, Square, Apple Pay, …) implements this interface.
 * Consuming code is coupled only to this contract — not to any provider SDK.
 *
 * Security invariants:
 *
 *   1. createOrder() sets the amount SERVER-SIDE. The amount in CreateOrderRequest
 *      MUST come from the server's own plan/price data, never from client input.
 *
 *   2. verifySignature() MUST be called before treating any checkout response as
 *      authoritative. Throw SignatureVerificationException on mismatch.
 *
 *   3. handleWebhook() MUST verify the provider signature before parsing the event.
 *      Throw SignatureVerificationException on mismatch; WebhookException on parse errors.
 *
 * Tax/settlement note:
 *   Gateway providers (Razorpay) — the consuming application is the merchant of record
 *   and is responsible for GST invoicing. MoR providers (Paddle) — the provider is the
 *   seller of record and handles tax. Drivers should surface which model they use.
 *
 * @package StoneScriptPay\Contracts
 */
interface PaymentProvider
{
    /**
     * Create a payment order / checkout intent with a SERVER-SET amount.
     *
     * Returns an OrderResult containing the order ID and publishable key ID to
     * pass to the frontend for the hosted checkout.
     *
     * @param CreateOrderRequest $req
     * @return OrderResult
     * @throws PaymentException if the provider API call fails.
     */
    public function createOrder(CreateOrderRequest $req): OrderResult;

    /**
     * Verify the HMAC signature returned by the hosted checkout.
     *
     * Must be called before treating a payment response as authoritative.
     * Returns a VerificationResult on success.
     *
     * @param VerifyRequest $req
     * @return VerificationResult
     * @throws SignatureVerificationException if the HMAC does not match.
     */
    public function verifySignature(VerifyRequest $req): VerificationResult;

    /**
     * Handle an inbound provider webhook.
     *
     * Verifies the webhook signature, parses the event, and returns a
     * normalised WebhookEvent. The route handler dispatches on event type.
     *
     * @param WebhookRequest $req
     * @return WebhookEvent
     * @throws SignatureVerificationException if the webhook signature is invalid.
     * @throws WebhookException if the payload is malformed or the event is unreadable.
     */
    public function handleWebhook(WebhookRequest $req): WebhookEvent;

    /**
     * Create a recurring subscription.
     *
     * @param CreateSubscriptionRequest $req
     * @return SubscriptionResult
     * @throws PaymentException if the provider API call fails.
     */
    public function createSubscription(CreateSubscriptionRequest $req): SubscriptionResult;

    /**
     * Cancel a subscription.
     *
     * For most providers cancellation is effective at the end of the current
     * billing period — verify in the driver docs.
     *
     * @param string $subscriptionId Provider-assigned subscription ID.
     * @return SubscriptionResult Updated subscription state.
     * @throws PaymentException if the provider API call fails.
     */
    public function cancelSubscription(string $subscriptionId): SubscriptionResult;

    /**
     * Fetch current subscription state from the provider.
     *
     * @param string $subscriptionId Provider-assigned subscription ID.
     * @return SubscriptionResult Current subscription state.
     * @throws PaymentException if the provider API call fails or the subscription is not found.
     */
    public function getSubscription(string $subscriptionId): SubscriptionResult;

    /**
     * Refund a payment (full or partial).
     *
     * @param RefundRequest $req
     * @return RefundResult
     * @throws PaymentException if the provider API call fails.
     */
    public function refund(RefundRequest $req): RefundResult;

    /**
     * Which settlement model this driver implements.
     *
     * GATEWAY — the consuming application is the merchant of record and is
     *   responsible for GST/tax invoicing (e.g. Razorpay, PayPal-as-gateway).
     * MOR — the provider is the seller of record and handles tax itself
     *   (e.g. Paddle, LemonSqueezy).
     *
     * A consumer wiring its own billing orchestrator uses this to decide
     * whether an invoice-recording side is expected: under MOR the
     * orchestrator is constructed with a `null` invoice source and
     * webhook settlement simply acknowledges without recording locally.
     *
     * @return string 'gateway' | 'mor'
     */
    public function settlementModel(): string;
}
