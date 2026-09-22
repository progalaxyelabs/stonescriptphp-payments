<?php

declare(strict_types=1);

namespace Tests\Unit\DTO;

use PHPUnit\Framework\TestCase;
use StoneScriptPay\DTO\SubscriptionResult;

class SubscriptionResultTest extends TestCase
{
    public function test_is_active_returns_true_for_active_status(): void
    {
        $result = new SubscriptionResult('sub_123', 'active');
        $this->assertTrue($result->isActive());
    }

    public function test_is_active_returns_true_for_authenticated_status(): void
    {
        $result = new SubscriptionResult('sub_123', 'authenticated');
        $this->assertTrue($result->isActive());
    }

    public function test_is_active_returns_false_for_cancelled_status(): void
    {
        $result = new SubscriptionResult('sub_123', 'cancelled');
        $this->assertFalse($result->isActive());
    }

    public function test_is_cancelled_returns_true_for_cancelled_status(): void
    {
        $result = new SubscriptionResult('sub_123', 'cancelled');
        $this->assertTrue($result->isCancelled());
    }

    public function test_is_cancelled_returns_false_for_active_status(): void
    {
        $result = new SubscriptionResult('sub_123', 'active');
        $this->assertFalse($result->isCancelled());
    }

    public function test_defaults_are_correct(): void
    {
        $result = new SubscriptionResult('sub_123', 'created');
        $this->assertNull($result->planId);
        $this->assertNull($result->currentStart);
        $this->assertNull($result->currentEnd);
        $this->assertNull($result->endAt);
        $this->assertSame(0, $result->paidCount);
        $this->assertSame(0, $result->remainingCount);
        $this->assertSame([], $result->raw);
    }
}
