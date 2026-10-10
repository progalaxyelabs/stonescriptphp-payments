<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Orders;

/**
 * Reduces a gateway payload to the fields that are safe to keep with a captured payment, plus the SHA-256 of the full
 * original. pay_captured_payments.raw_payload outlives the inbox's raw body (it is an accounting record), so it must hold NO
 * personal data: the payer's e-mail, phone, card and UPI details that a gateway echoes are dropped, never stored.
 *
 * Only allow-listed keys survive, and only when the VALUE has the expected format (an id, an ISO currency, a number, our own
 * order reference, a uuid...); a value of the wrong shape is dropped, not repaired. The same rules are enforced again, on the
 * server side, by the SQL function _pay_capture_raw_allowlist() that pay_apply_capture() applies to whatever it is handed, so a
 * caller that bypasses this class still cannot store arbitrary JSON. Keep the two in step.
 */
final class RawPayloadAllowlist
{
    /**
     * @param array<string,mixed> $payment a Razorpay payment entity, or a PayPal capture resource
     * @return string JSON: {"fields": {...}, "body_sha256": "..."}
     */
    public static function forPayment(array $payment, string $fullBodySha256): string
    {
        return json_encode(
            ['fields' => self::filter($payment), 'body_sha256' => $fullBodySha256],
            JSON_INVALID_UTF8_SUBSTITUTE | JSON_THROW_ON_ERROR | JSON_PRESERVE_ZERO_FRACTION | JSON_FORCE_OBJECT,   // every level is an object, even when empty (as the SQL side stores it)
        );
    }

    /**
     * @param array<string,mixed> $in
     * @return array<string,mixed>
     */
    public static function filter(array $in): array
    {
        $out = [];
        foreach ($in as $key => $v) {
            $s = is_string($v) ? $v : null;
            switch ($key) {
                case 'id':
                case 'order_id':
                    if ($s !== null && preg_match('/^[A-Za-z0-9_-]{1,100}$/D', $s) === 1) {
                        $out[$key] = $v;
                    }
                    break;
                case 'currency':
                    if ($s !== null && preg_match('/^[A-Z]{3}$/D', $s) === 1) {
                        $out[$key] = $v;
                    }
                    break;
                case 'status':
                case 'method':
                    if ($s !== null && preg_match('/^[A-Za-z_]{1,32}$/D', $s) === 1) {
                        $out[$key] = $v;
                    }
                    break;
                case 'captured':
                    if (is_bool($v)) {
                        $out[$key] = $v;
                    }
                    break;
                case 'amount_refunded':
                case 'created_at':
                case 'captured_at':
                    if (is_int($v) || is_float($v)) {
                        $out[$key] = $v;
                    }
                    break;
                case 'amount':
                    if (is_int($v) || is_float($v)) {
                        $out[$key] = $v;
                    } elseif (is_array($v)) {
                        $a = [];
                        $val = $v['value'] ?? null;
                        if ((is_string($val) || is_int($val) || is_float($val)) && preg_match('/^[0-9]{1,12}(\.[0-9]{1,4})?$/D', (string) $val) === 1) {
                            $a['value'] = $val;
                        }
                        $cc = $v['currency_code'] ?? null;
                        if (is_string($cc) && preg_match('/^[A-Z]{3}$/D', $cc) === 1) {
                            $a['currency_code'] = $cc;
                        }
                        $out['amount'] = $a;
                    }
                    break;
                case 'custom_id':
                    if ($s !== null && preg_match('/^[A-Za-z0-9_|.-]{1,127}$/D', $s) === 1) {
                        $out[$key] = $v;
                    }
                    break;
                case 'create_time':
                case 'update_time':
                    if ($s !== null && preg_match('/^[0-9TZ:.+-]{10,40}$/D', $s) === 1) {
                        $out[$key] = $v;
                    }
                    break;
                case 'notes':
                    if (is_array($v)) {
                        $n = self::notes($v);
                        if ($n !== []) {
                            $out['notes'] = $n;
                        }
                    }
                    break;
                default:
                    break;  // everything else is dropped
            }
        }

        return $out;
    }

    /**
     * @param array<mixed> $notes
     * @return array<string,string>
     */
    private static function notes(array $notes): array
    {
        $n = [];
        foreach (['order_id' => '/^ord_[0-9a-f]{32}$/D', 'invoice_ref' => '/^ord_[0-9a-f]{32}$/D',
                  'platform_code' => '/^[A-Za-z0-9_.-]{1,50}$/D',
                  'tenant_id' => '/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/D'] as $k => $re) {
            $v = $notes[$k] ?? null;
            if (is_string($v) && preg_match($re, $v) === 1) {
                $n[$k] = $v;
            }
        }

        return $n;
    }
}
