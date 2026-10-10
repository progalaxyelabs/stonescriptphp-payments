<?php

declare(strict_types=1);

namespace Tests\Http;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use StoneScriptPay\Http\Orders\RawPayloadAllowlist;

/**
 * The PHP allow-list (RawPayloadAllowlist) and the SQL one (_pay_capture_raw_allowlist, applied inside pay_apply_capture) must keep
 * and drop exactly the same keys and values. Every case runs through both and the surviving fields are compared; positive and
 * negative cases alike. Skipped without PAYMENTS_TEST_PG_DSN.
 */
final class RawAllowlistParityTest extends TestCase
{
    private const TENANT = '00000000-0000-0000-0000-0000000b0001';
    private const ORD = 'ord_0123456789abcdef0123456789abcdef';

    private \PDO $pdo;

    protected function setUp(): void
    {
        $dsn = getenv('PAYMENTS_TEST_PG_DSN');
        if ($dsn === false || $dsn === '' || !extension_loaded('pdo_pgsql')) {
            $this->markTestSkipped('PAYMENTS_TEST_PG_DSN / pdo_pgsql not available: the allow-list parity tests did not run.');
        }
        $this->pdo = new \PDO($dsn, null, null, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
    }

    /** @return iterable<string,array{0:array<string,mixed>}> */
    public static function payloads(): iterable
    {
        yield 'a clean entity' => [['id' => 'pay_1', 'order_id' => 'order_A', 'amount' => 100, 'currency' => 'INR', 'status' => 'captured', 'method' => 'upi', 'captured' => true]];
        yield 'hostile mix' => [RawPayloadAllowlistTest::hostile()];
        yield 'currency lower case' => [['currency' => 'inr']];
        yield 'currency too long' => [['currency' => 'INRR']];
        yield 'currency with newline suffix' => [['currency' => "INR\n"]];
        yield 'currency as number' => [['currency' => 356]];
        yield 'status with space' => [['status' => 'captured now']];
        yield 'status with digit' => [['status' => 'cap1']];
        yield 'status with newline suffix' => [['status' => "captured\n"]];
        yield 'status too long' => [['status' => str_repeat('a', 33)]];
        yield 'method as email' => [['method' => 'a@b.test']];
        yield 'id with newline suffix' => [['id' => "pay_x\n"]];
        yield 'id with space' => [['id' => 'pay x']];
        yield 'id 101 chars' => [['id' => str_repeat('a', 101)]];
        yield 'id 100 chars' => [['id' => str_repeat('a', 100)]];
        yield 'id as number' => [['id' => 12345]];
        yield 'order_id as email' => [['order_id' => 'a@b.test']];
        yield 'amount integer' => [['amount' => 58882]];
        yield 'amount float' => [['amount' => 499.5]];
        yield 'amount string' => [['amount' => '58882']];
        yield 'amount list' => [['amount' => [1, 2]]];
        yield 'amount null' => [['amount' => null]];
        yield 'amount object good' => [['amount' => ['value' => '499.00', 'currency_code' => 'USD']]];
        yield 'amount object int value' => [['amount' => ['value' => 499, 'currency_code' => 'USD']]];
        yield 'amount object float value' => [['amount' => ['value' => 499.25, 'currency_code' => 'USD']]];
        yield 'amount object bad value' => [['amount' => ['value' => '1;DROP', 'currency_code' => 'INR']]];
        yield 'amount object exponent value' => [['amount' => ['value' => '1e5', 'currency_code' => 'INR']]];
        yield 'amount object too many decimals' => [['amount' => ['value' => '1.12345', 'currency_code' => 'INR']]];
        yield 'amount object value newline' => [['amount' => ['value' => "10\n", 'currency_code' => 'INR']]];
        yield 'amount object bad currency' => [['amount' => ['value' => '10.00', 'currency_code' => 'usd']]];
        yield 'amount object extra keys' => [['amount' => ['value' => '10.00', 'currency_code' => 'USD', 'breakdown' => ['x' => 1]]]];
        yield 'amount object empty' => [['amount' => []]];
        yield 'amount object missing currency' => [['amount' => ['value' => '10.00']]];
        yield 'custom_id good' => [['custom_id' => self::ORD . '|a.b-c']];
        yield 'custom_id with space' => [['custom_id' => 'x y']];
        yield 'custom_id newline suffix' => [['custom_id' => "abc\n"]];
        yield 'custom_id 128 chars' => [['custom_id' => str_repeat('a', 128)]];
        yield 'create_time good' => [['create_time' => '2026-10-10T10:00:00Z', 'update_time' => '2026-10-10T10:00:01.123+05:30']];
        yield 'create_time too short' => [['create_time' => '2026-10']];
        yield 'create_time with letters' => [['create_time' => '2026-10-10T10:00:00Zjunk']];
        yield 'create_time newline suffix' => [['create_time' => "2026-10-10T10:00:00Z\n"]];
        yield 'create_time as number' => [['create_time' => 1760000000]];
        yield 'created_at number' => [['created_at' => 1760000000, 'captured_at' => 1760000001, 'amount_refunded' => 0]];
        yield 'created_at string' => [['created_at' => '1760000000']];
        yield 'created_at float' => [['created_at' => 1760000000.5]];
        yield 'captured as string' => [['captured' => 'true']];
        yield 'captured as int' => [['captured' => 1]];
        yield 'notes good' => [['notes' => ['order_id' => self::ORD, 'invoice_ref' => self::ORD, 'platform_code' => 'plat-1.x_y', 'tenant_id' => self::TENANT]]];
        yield 'notes uuid upper case' => [['notes' => ['tenant_id' => strtoupper(self::TENANT)]]];
        yield 'notes uuid mixed case' => [['notes' => ['tenant_id' => '00000000-0000-0000-0000-0000000B0001']]];
        yield 'notes uuid newline suffix' => [['notes' => ['tenant_id' => self::TENANT . "\n"]]];
        yield 'notes uuid no dashes' => [['notes' => ['tenant_id' => str_replace('-', '', self::TENANT)]]];
        yield 'notes order_id upper hex' => [['notes' => ['order_id' => 'ord_0123456789ABCDEF0123456789ABCDEF']]];
        yield 'notes order_id short' => [['notes' => ['order_id' => 'ord_0123']]];
        yield 'notes order_id newline suffix' => [['notes' => ['order_id' => self::ORD . "\n"]]];
        yield 'notes invoice_ref free text' => [['notes' => ['invoice_ref' => 'free text']]];
        yield 'notes platform bad char' => [['notes' => ['platform_code' => 'bad code!']]];
        yield 'notes platform 51 chars' => [['notes' => ['platform_code' => str_repeat('a', 51)]]];
        yield 'notes platform newline suffix' => [['notes' => ['platform_code' => "plat\n"]]];
        yield 'notes extra keys' => [['notes' => ['email' => 'n@example.test', 'address' => '1 Street']]];
        yield 'notes as list' => [['notes' => ['a', 'b']]];
        yield 'notes empty' => [['notes' => []]];
        yield 'notes as string' => [['notes' => 'text']];
        yield 'unknown and personal keys' => [['email' => 'p@example.test', 'contact' => '+910000000000', 'vpa' => 'x@upi', 'card' => ['last4' => '4242'], 'description' => 'secret']];
        yield 'empty payload' => [[]];
    }

    /** @param array<string,mixed> $payload */
    #[DataProvider('payloads')]
    public function test_php_and_sql_keep_exactly_the_same_fields(array $payload): void
    {
        $php = json_decode(RawPayloadAllowlist::forPayment($payload, str_repeat('b', 64)), true, 512, JSON_THROW_ON_ERROR)['fields'];

        $st = $this->pdo->prepare('SELECT (_pay_capture_raw_allowlist(?::text) -> ?)::text');
        $st->execute([json_encode($payload, JSON_THROW_ON_ERROR | JSON_PRESERVE_ZERO_FRACTION | JSON_FORCE_OBJECT), 'fields']);
        $sql = json_decode((string) $st->fetchColumn(), true, 512, JSON_THROW_ON_ERROR);

        self::assertSame(self::norm($php), self::norm($sql), 'PHP and SQL disagree for ' . json_encode($payload));
        // the same filter applied to the PHP output (the {fields, body_sha256} form) is a fixed point on the SQL side
        $st2 = $this->pdo->prepare('SELECT (_pay_capture_raw_allowlist(?::text) -> ?)::text');
        $st2->execute([RawPayloadAllowlist::forPayment($payload, str_repeat('b', 64)), 'fields']);
        self::assertSame(self::norm($php), self::norm(json_decode((string) $st2->fetchColumn(), true, 512, JSON_THROW_ON_ERROR)));
    }

    /** key-sorted at every level, so only the content is compared (JSON object key order is not significant) */
    private static function norm(mixed $v): mixed
    {
        if (is_array($v)) {
            $v = array_map([self::class, 'norm'], $v);
            ksort($v);
        }

        return $v;
    }

    public function test_sql_stores_null_for_unparseable_or_non_object_input(): void
    {
        foreach (['not json', '[1,2]', '"x"', '', 'null'] as $raw) {
            $st = $this->pdo->prepare('SELECT _pay_capture_raw_allowlist(?::text) IS NULL');
            $st->execute([$raw]);
            self::assertTrue((bool) $st->fetchColumn(), "input [$raw] must store NULL");
        }
    }
}
