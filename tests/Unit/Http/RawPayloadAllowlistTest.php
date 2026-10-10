<?php

declare(strict_types=1);

namespace Tests\Http;

use PHPUnit\Framework\TestCase;
use StoneScriptPay\Http\Orders\RawPayloadAllowlist;

final class RawPayloadAllowlistTest extends TestCase
{
    /** @return array<string,mixed> */
    public static function hostile(): array
    {
        return [
            'id' => 'pay_ok1', 'order_id' => 'order_AAA', 'amount' => 58882, 'currency' => 'INR', 'status' => 'captured',
            'method' => 'upi', 'captured' => true, 'amount_refunded' => 0, 'created_at' => 1760000000,
            'email' => 'payer@example.test', 'contact' => '+910000000000', 'vpa' => 'x@upi', 'card' => ['last4' => '4242'],
            'description' => 'secret text',
            'notes' => ['order_id' => 'ord_0123456789abcdef0123456789abcdef', 'tenant_id' => '00000000-0000-0000-0000-0000000b0001',
                        'platform_code' => 'plat', 'email' => 'n@example.test', 'address' => '1 Street'],
        ];
    }

    public function test_only_allow_listed_keys_survive_and_no_personal_data_does(): void
    {
        $json = RawPayloadAllowlist::forPayment(self::hostile(), str_repeat('a', 64));
        foreach (['payer@example', '+91', 'x@upi', '4242', 'secret text', 'Street', 'n@example'] as $leak) {
            self::assertStringNotContainsString($leak, $json);
        }
        $d = json_decode($json, true, 512, JSON_THROW_ON_ERROR);
        self::assertSame(str_repeat('a', 64), $d['body_sha256']);
        self::assertSame('pay_ok1', $d['fields']['id']);
        self::assertEqualsCanonicalizing(['order_id', 'tenant_id', 'platform_code'], array_keys($d['fields']['notes']));
    }

    public function test_a_value_of_the_wrong_format_is_dropped_not_repaired(): void
    {
        $f = RawPayloadAllowlist::filter([
            'id' => "pay_x\n", 'currency' => 'inr', 'status' => 'captured now', 'method' => 'a@b.test',
            'amount' => ['value' => '1;DROP', 'currency_code' => 'INR'], 'custom_id' => 'x y',
            'notes' => ['order_id' => 'free text', 'tenant_id' => 'not-a-uuid', 'platform_code' => 'bad code!'],
            'captured' => 'true', 'created_at' => '1760000000',
        ]);
        self::assertSame(['amount' => ['currency_code' => 'INR']], $f);
    }

    public function test_paypal_shaped_amount_and_times_are_kept_when_well_formed(): void
    {
        $f = RawPayloadAllowlist::filter(['id' => 'CAP1', 'amount' => ['value' => '499.00', 'currency_code' => 'USD', 'junk' => 'x'],
            'custom_id' => 'ord_0123456789abcdef0123456789abcdef', 'create_time' => '2026-10-10T10:00:00Z', 'payer' => ['email_address' => 'p@example.test']]);
        self::assertSame(['id' => 'CAP1', 'amount' => ['value' => '499.00', 'currency_code' => 'USD'],
            'custom_id' => 'ord_0123456789abcdef0123456789abcdef', 'create_time' => '2026-10-10T10:00:00Z'], $f);
    }
}
