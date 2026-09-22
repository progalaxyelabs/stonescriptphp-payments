-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_money_quantity_milli_to_decimal_string — split from Gst/024_gst_money.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

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

-- Render a milli-unit quantity back to a trimmed decimal string ("2.5","0.333","1").
-- Mirrors Money::quantityMilliUnitsToDecimalString. Canonical quantity output -> SQL.

CREATE OR REPLACE FUNCTION inv_money_quantity_milli_to_decimal_string(p_milli BIGINT)
RETURNS TEXT AS $$
DECLARE
    v_neg   BOOLEAN := p_milli < 0;
    v_abs   BIGINT  := abs(p_milli);
    v_thou  INT     := (v_abs % 1000)::INT;  -- 1000 = milli-units per unit
    v_out   TEXT;
BEGIN
    v_out := CASE WHEN v_neg THEN '-' ELSE '' END || (v_abs / 1000)::TEXT;
    IF v_thou <> 0 THEN
        v_out := v_out || '.' || rtrim(lpad(v_thou::TEXT, 3, '0'), '0');
    END IF;
    RETURN v_out;
END;
$$ LANGUAGE plpgsql IMMUTABLE;
