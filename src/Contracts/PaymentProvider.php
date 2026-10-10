<?php

declare(strict_types=1);

namespace StoneScriptPay\Contracts;

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
 *   4. mode() is derived from the credentials/endpoint the driver is configured with,
 *      never from caller input or a default: 'test' and 'live' orders, payments, invoices
 *      and invoice numbers never mix, and a driver that cannot tell throws.
 *
 *   5. fetchPayment() is the independent way to confirm a payment: it asks the gateway,
 *      using our own credentials, what happened to a payment id. Anything that applies a
 *      payment on an operator's say-so must call it first.
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
     * The HTTP header (lower-case) that carries this gateway's webhook signature, so the ingress never guesses or
     * defaults it: Razorpay 'x-razorpay-signature'; PayPal 'paypal-transmission-sig' (its verification reads several
     * headers, this is the one that must be present).
     */
    public function webhookSignatureHeader(): string;

    /**
     * Whether this driver talks to the gateway's sandbox or production environment.
     *
     * Derived from the configured credentials / base URL (Razorpay: the key id prefix
     * rzp_test_ / rzp_live_; PayPal: sandbox vs production base URL). The order, its
     * invoice number series and the capture all carry this mode and are refused when it
     * disagrees.
     *
     * @return string 'live' | 'test'
     * @throws PaymentException if the mode cannot be determined (it is never assumed).
     */
    public function mode(): string;

    /**
     * The publishable (non-secret) client identifier the hosted checkout needs: Razorpay key
     * id, PayPal client id. Stable for a driver instance; lets a retried order creation return
     * the same checkout data without calling the gateway again.
     */
    public function publishableKeyId(): string;

    /**
     * Find an order previously created with this receipt (our order_ref), or null. Lets an order creation that crashed
     * between the gateway call and our attach find the gateway order again instead of creating a second one. A gateway
     * with no receipt lookup (PayPal) returns null and relies on its request-id idempotency instead.
     */
    public function findOrderByReceipt(string $receipt): ?OrderResult;

    /**
     * Fetch a payment from the gateway by its id, normalised.
     *
     * @param string $paymentId The gateway's payment id (Razorpay pay_..., PayPal capture id).
     * @return PaymentDetails
     * @throws PaymentException if the gateway call fails or the payment does not exist.
     */
    public function fetchPayment(string $paymentId): PaymentDetails;

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
