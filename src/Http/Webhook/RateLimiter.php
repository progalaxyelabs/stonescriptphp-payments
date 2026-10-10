<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

/**
 * Hook for rate limiting the PUBLIC webhook route. The route is unauthenticated until the signature is verified, and for
 * a gateway like PayPal verification costs an outbound API call, so an unthrottled caller can make the server call out.
 * The ingress consults the limiter BEFORE verifying anything and answers 429 when it says no.
 *
 * The library ships no limiter (there is no shared store it could assume): wire one on the same store the platform already
 * uses for request limiting (a Redis counter, the framework's rate limiter, an nginx limit_req zone in front). Keys are
 * "<gateway>|<client>" where the client is the address the platform trusts (see TRUSTED_PROXIES in the framework).
 */
interface RateLimiter
{
    /** @return bool true to let the request through, false to answer 429 */
    public function allow(string $key): bool;
}
