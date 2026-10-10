<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Entitlement;

use StoneScriptPay\Http\Webhook\AlertSink;
use StoneScriptPay\Http\Webhook\SqlFunctionCaller;
use StoneScriptPHP\ApiResponse;
use StoneScriptPHP\Routing\MiddlewareInterface;

/**
 * The StoneScriptPHP middleware over EntitlementGuard: reads the ONE entitlement store (ent_get) for the authenticated tenant and
 * answers 423 for a write by a read-only tenant. Requires the framework; EntitlementGuard itself does not.
 *
 * Register it after the auth middleware. $tenantResolver receives the request array and returns [tenantId, platformCode] for the authenticated
 * caller, or null for an unauthenticated one (left to the auth layer).
 *
 * THE LOOKUP goes to the MAIN database: $mainDb (FrameworkMainDbScope) clears the tenant context for the call and restores it afterwards, exactly as
 * the framework's own subscription middleware does. Result rows are normalised (objects, or the JSON a gateway pre-decodes) to arrays.
 *
 * FAILURE POLICY (bounded fail-open). A customer must not be locked out by infrastructure trouble, but a blip must not make a lapsed tenant writable:
 *   - TRANSPORT failure (unreachable, timeout): serve the LAST-KNOWN decision for that tenant if it is under 10 minutes old, otherwise serve open.
 *     After $alertAfterFailures consecutive failures raise one alert 'entitlement.lookup_failing'.
 *   - DEPLOY failure (ent_get missing, PY050, a missing column, an EMPTY result): a deployment bug, not a blip. Logged at ERROR with the stable token
 *     ENTITLEMENT_DEPLOY_ERROR and alerted ('entitlement.deploy_error', at most once every 5 minutes); the request is still served.
 *   - On every fail-open path NO X-Subscription-State header is sent: the state is unknown, and the client must not be told otherwise.
 */
final class EntitlementMiddleware implements MiddlewareInterface
{
    public const TOKEN_DEPLOY = 'ENTITLEMENT_DEPLOY_ERROR';
    public const TOKEN_FAILING = 'ENTITLEMENT_LOOKUP_FAILING';

    /** @param callable(array<string,mixed>):?array{0:string,1:string} $tenantResolver */
    public function __construct(
        private readonly SqlFunctionCaller $db,
        private readonly EntitlementGuard $guard,
        private readonly mixed $tenantResolver,
        private readonly string $product = 'default',
        private readonly ?MainDbScope $mainDb = null,
        private readonly ?AlertSink $alerts = null,
        private readonly ?DecisionCache $cache = null,
        private readonly int $alertAfterFailures = 5,
        private readonly ?\Closure $clock = null,
        private readonly ?\Closure $headerSink = null,
    ) {}

    public function handle(array $request, callable $next): ?ApiResponse
    {
        $path = (string) ($request['path'] ?? parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH) ?? '/');
        if ($this->guard->isExempt($path)) {
            return $next($request);
        }
        $who = ($this->tenantResolver)($request);
        if ($who === null) {
            return $next($request);
        }
        $method = (string) ($request['method'] ?? ($_SERVER['REQUEST_METHOD'] ?? 'GET'));
        [$row, $fresh] = $this->lookup($who[0], $who[1]);

        $decision = $this->guard->decide($method, $path, $row);
        if ($fresh) {
            $this->sendHeader($decision->stateHeader);
        }
        if ($decision->allowed) {
            return $next($request);
        }

        return new ApiResponse('error', $decision->message, $decision->data, $decision->httpStatus);
    }

    /**
     * @return array{0:?array<string,mixed>,1:bool} the row to decide on (null = serve open) and whether it is a fresh answer (header allowed)
     */
    private function lookup(string $tenant, string $platform): array
    {
        $cache = $this->cache ?? new InMemoryDecisionCache();
        $key = $tenant . '|' . $platform . '|' . $this->product;
        $now = $this->now();
        try {
            $call = fn () => $this->db->call('ent_get', [$tenant, $platform, $this->product]);
            $rows = $this->mainDb !== null ? $this->mainDb->run($call) : $call();
            $row = self::normaliseRow($rows);
            if ($row === null) {
                throw new \UnexpectedValueException('ent_get returned no row (it always answers): the entitlement functions are not deployed as expected');
            }
        } catch (\Throwable $e) {
            return $this->failed($e, $key, $cache, $now);
        }
        $cache->recordSuccess();
        $cache->put($key, $row, $now);

        return [$row, true];
    }

    /** @return array{0:?array<string,mixed>,1:bool} */
    private function failed(\Throwable $e, string $key, DecisionCache $cache, int $now): array
    {
        $kind = $e instanceof \UnexpectedValueException ? LookupFailure::DEPLOY : LookupFailure::classify($e);
        $last = $cache->get($key, $now);
        if ($kind === LookupFailure::DEPLOY) {
            error_log('[payments][' . self::TOKEN_DEPLOY . '] ' . $e->getMessage());
            if ($cache->claimAlertSlot('deploy_error', $now, 300)) {            // per worker, not per request
                $this->alert('entitlement.deploy_error', self::TOKEN_DEPLOY . ': ' . $e->getMessage());
            }

            return [$last, false];
        }
        $n = $cache->recordFailure();
        error_log('[payments][' . self::TOKEN_FAILING . '] lookup failed (' . $kind . ', ' . $n . ' in a row): ' . $e->getMessage());
        if ($n === $this->alertAfterFailures) {
            $this->alert('entitlement.lookup_failing', self::TOKEN_FAILING . ': ' . $n . ' consecutive entitlement lookups failed: ' . $e->getMessage());
        }

        return [$last, false];
    }

    /**
     * Rows come back as arrays, objects (a gateway's decoded JSON) or a single column holding the JSON. Anything else, or nothing, is null.
     *
     * @return ?array<string,mixed>
     */
    public static function normaliseRow(mixed $rows): ?array
    {
        if (is_object($rows)) {
            $rows = (array) $rows;
        }
        if (!is_array($rows) || $rows === []) {
            return null;
        }
        $row = array_is_list($rows) ? $rows[0] : $rows;
        if (is_object($row)) {
            $row = (array) $row;
        }
        if (!is_array($row) || $row === []) {
            return null;
        }
        if (array_key_exists('ent_get', $row)) {
            $row = is_string($row['ent_get']) ? json_decode($row['ent_get'], true) : $row['ent_get'];
            if (is_object($row)) {
                $row = (array) $row;
            }
            if (!is_array($row)) {
                return null;
            }
        }

        return array_key_exists('o_status', $row) ? $row : null;
    }

    private function alert(string $kind, string $detail): void
    {
        if ($this->alerts === null) {
            return;
        }
        try {
            $this->alerts->alert($kind, 0, 'entitlement', $kind, $detail);
        } catch (\Throwable $e) {
            error_log('[payments] entitlement alert sink failed: ' . $e->getMessage());
        }
    }

    private function now(): int
    {
        return $this->clock !== null ? (int) ($this->clock)() : time();
    }

    private function sendHeader(string $value): void
    {
        if ($this->headerSink !== null) {
            ($this->headerSink)(EntitlementGuard::HEADER_NAME, $value);

            return;
        }
        if (!headers_sent()) {
            header(EntitlementGuard::HEADER_NAME . ': ' . $value);
        }
    }
}
