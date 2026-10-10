<?php

declare(strict_types=1);

namespace Tests\Http\Support;

/**
 * SqlFunctionCaller over the StoneScriptDB Gateway's POST /call, the way a deployed platform reaches the database: typed JSON
 * parameters (null stays null, booleans and integers stay typed, the server types each parameter from the function signature),
 * rows back as JSON objects.
 */
final class GatewayHttpCaller extends FailableCaller
{
    public function __construct(private readonly string $baseUrl, private readonly string $platform, private readonly string $schema) {}

    public function call(string $function, array $args): array
    {
        $this->maybeFail();
        $ch = curl_init(rtrim($this->baseUrl, '/') . '/call');
        curl_setopt_array($ch, [
            CURLOPT_POST => true,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT => 30,
            CURLOPT_HTTPHEADER => ['Content-Type: application/json'],
            CURLOPT_POSTFIELDS => json_encode(['platform' => $this->platform, 'schema_name' => $this->schema, 'function' => $function, 'params' => array_values($args)], JSON_THROW_ON_ERROR),
        ]);
        $body = curl_exec($ch);
        $code = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        $json = is_string($body) ? json_decode($body, true) : null;
        if ($code < 200 || $code >= 300 || !is_array($json)) {
            // the gateway answers errors as {error, message}; surface the message (it carries the SQLSTATE text) like PDO would
            // {error, message, cause}: the gateway keeps the SQLSTATE out of the answer; `cause` is the SQL's own message
            $msg = is_array($json) ? trim((string) ($json['message'] ?? $json['error'] ?? '') . ' ' . (string) ($json['cause'] ?? '')) : (string) $body;
            throw new \PDOException("gateway /call {$function} failed (HTTP {$code}): {$msg}");
        }

        return $json['rows'] ?? [];
    }
}
