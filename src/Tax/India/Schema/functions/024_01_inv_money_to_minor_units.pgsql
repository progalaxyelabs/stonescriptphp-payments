-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_money_to_minor_units — split from Gst/024_gst_money.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

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

-- Parse a caller-supplied decimal money STRING into exact integer paisa.
-- Mirrors Money::toMinorUnits(string). (An int in PHP is already paisa and
-- passes through untouched — in SQL a BIGINT paisa value simply IS the result,
-- so no function is needed for that leg; this handles the decimal-string leg.)

CREATE OR REPLACE FUNCTION inv_money_to_minor_units(p_amount TEXT)
RETURNS BIGINT AS $$
DECLARE
    v_trim TEXT;
    v_m    TEXT[];
    v_frac TEXT;
    v_val  BIGINT;
BEGIN
    v_trim := btrim(p_amount);
    -- same shape PHP's DECIMAL_PATTERN accepts: optional '-', digits, optional '.digits'
    v_m := regexp_match(v_trim, '^(-)?(\d+)(?:\.(\d+))?$');
    IF v_m IS NULL THEN
        RAISE EXCEPTION '"%" is not a valid decimal money amount (expected e.g. "1180.50", "-12", "0").', p_amount
            USING ERRCODE = 'ER022';
    END IF;

    v_frac := COALESCE(v_m[3], '');
    IF length(v_frac) > 2 THEN
        -- PHP MoneyPrecisionException: reject, never silently round a 3rd decimal away.
        RAISE EXCEPTION '"%" carries more than 2 decimal places — money must be exact to the paisa; round it explicitly to 2dp at your own boundary.', p_amount
            USING ERRCODE = 'ER023';
    END IF;

    -- integer_part concatenated with the 2dp fractional part -> paisa. 2 = decimal places in a paisa.
    v_val := (v_m[2] || rpad(v_frac, 2, '0'))::BIGINT;
    IF v_m[1] = '-' THEN
        v_val := -v_val;
    END IF;
    RETURN v_val;
END;
$$ LANGUAGE plpgsql IMMUTABLE;
