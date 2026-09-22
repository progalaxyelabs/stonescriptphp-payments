-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_money_half_up_divide — split from Gst/024_gst_money.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: GST money primitives — PORT of stonescriptphp-invoice `Lib/Money.php`
--
-- Money as INTEGER MINOR UNITS (paisa) — NEVER a float, anywhere. This is the
-- exact SQL counterpart of the PHP `Lib\Money` class:
-- the PHP engine's half-up division is `intdiv(2n + d, 2d)` — an EXACT integer
-- identity with no float / no representation error. Postgres integer division
-- (`/` on bigints) truncates toward zero, which for the non-negative operands
-- this identity is only ever called with is identical to PHP's `intdiv`. So the
-- two implementations are provably paisa-identical (proven in 031 differential).
--
-- NOTE ON THE "half-up = ROUND()" CLAIM: we do NOT rely on
-- Postgres NUMERIC ROUND() half-away-from-zero at all — we use the SAME exact
-- integer identity PHP uses, which is stronger (no NUMERIC, no float, ever).
-- 031 additionally asserts ROUND() *agrees* with the identity on every golden
-- tie, documenting the equivalence, but the engine never depends on it.
--
-- FORMULAE live in functions; VALUES live in data (026 config/slab/state tables).
-- The only literals in these bodies are UNIT-SCALE conversion constants, each
-- annotated: 100 (paisa per rupee), 1000 (milli-units per unit), 10000
-- (ten-thousandths — the basis-points-x100 rate scale), 2 (a tax head halved
-- into two equal parts). These are units, not business values.
--
-- Custom SQLSTATEs (continuing the ERxxx scheme from 003/017/019/020/023):
--   ER022  money string is not a valid decimal amount              -> 400
--   ER023  money string carries more than 2 decimal places         -> 400  (PHP MoneyPrecisionException)
--   ER024  half_up_divide misuse (bad numerator/denominator)        -> 500  (PHP \LogicException — internal, never caller-triggerable)
--   ER025  quantity is not a valid <=3dp decimal                   -> 400
--   ER026  fx_rate / positive-decimal string invalid or <= 0        -> 400
--
-- NO now()/CURRENT_DATE anywhere — these functions are pure (no timestamps at all).

-- Half-up division of two non-negative integers, EXACTLY, via (2n + d) / (2d).
-- Mirrors Money::halfUpDivide. The internal guards are PHP's \LogicException
-- (ER024) — a bad call here is an engine bug, never a caller's invoice input.

CREATE OR REPLACE FUNCTION inv_money_half_up_divide(p_numerator BIGINT, p_denominator BIGINT)
RETURNS BIGINT AS $$
BEGIN
    IF p_denominator <= 0 THEN
        RAISE EXCEPTION 'half_up_divide denominator must be positive (got %)', p_denominator USING ERRCODE = 'ER024';
    END IF;
    IF p_numerator < 0 THEN
        RAISE EXCEPTION 'half_up_divide numerator must not be negative (got %)', p_numerator USING ERRCODE = 'ER024';
    END IF;
    -- 2 = the half-up tie-breaking identity's factor; integer division truncates
    -- toward zero, == floor for the non-negative operands, == PHP intdiv exactly.
    RETURN (2 * p_numerator + p_denominator) / (2 * p_denominator);
END;
$$ LANGUAGE plpgsql IMMUTABLE;
