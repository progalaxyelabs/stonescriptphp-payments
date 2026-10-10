<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Routes;

use StoneScriptPay\Http\Webhook\IngressResult;
use StoneScriptPay\Http\Webhook\WebhookIngress;
use StoneScriptPHP\ApiResponse;
use StoneScriptPHP\IRouteHandler;

/**
 * POST {prefix}/webhook/{gateway} (RoutePaths::webhook(), '/pay/webhook/{gateway}' by default) - the StoneScriptPHP route over WebhookIngress.
 *
 * A thin adapter: it reads the raw body and headers, hands them to the ingress and renders its
 * answer in the framework's {status,message,data} shape. Register it as a PUBLIC route (the
 * gateway's signature, verified by the driver, is the authentication). Requires the framework;
 * WebhookIngress itself does not.
 */
final class PostWebhookRoute implements IRouteHandler
{
    public function __construct(
        private readonly string $gatewayCode,
        private readonly WebhookIngress $ingress,
    ) {}

    public function validation_rules(): array
    {
        return [];
    }

    public function process(): ApiResponse
    {
        $raw = file_get_contents('php://input');
        $headers = function_exists('getallheaders') ? (array) getallheaders() : self::headersFromServer($_SERVER);

        return $this->handleRaw($raw === false ? '' : $raw, $headers, isset($_SERVER['REMOTE_ADDR']) ? (string) $_SERVER['REMOTE_ADDR'] : null);
    }

    /**
     * @param array<string,string> $headers
     * @param ?string $clientKey The caller address the platform trusts, for the optional RateLimiter.
     */
    public function handleRaw(string $rawBody, array $headers, ?string $clientKey = null): ApiResponse
    {
        return self::render($this->ingress->handle($this->gatewayCode, $rawBody, $headers, $clientKey));
    }

    private static function render(IngressResult $r): ApiResponse
    {
        return $r->isOk() ? res_ok($r->data, $r->message) : res_error($r->message, $r->httpStatus);
    }

    /**
     * @param array<string,mixed> $server
     * @return array<string,string>
     */
    private static function headersFromServer(array $server): array
    {
        $out = [];
        foreach ($server as $k => $v) {
            if (str_starts_with((string) $k, 'HTTP_') && is_string($v)) {
                $out[strtolower(str_replace('_', '-', substr((string) $k, 5)))] = $v;
            }
        }
        if (isset($server['CONTENT_TYPE']) && is_string($server['CONTENT_TYPE'])) {
            $out['content-type'] = $server['CONTENT_TYPE'];
        }

        return $out;
    }
}
