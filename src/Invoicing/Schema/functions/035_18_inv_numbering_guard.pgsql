-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: inv_numbering_guard
--
-- One row guard for the three numbering tables (it branches on TG_TABLE_NAME):
--   inv_series              identity columns (code, issuer, kind, mode, prefix, sep, width,
--                           fy_reset) are immutable; only is_active may change; never deleted.
--   inv_series_counter      last_number only moves forward (PY018) - hand edits that go
--                           backwards are refused, forward moves belong to _inv_series_adopt;
--                           the key never changes; a counter that has issued is never deleted.
--   inv_series_adoptions    append-only audit.
CREATE OR REPLACE FUNCTION inv_numbering_guard() RETURNS TRIGGER AS $$
BEGIN
    IF TG_TABLE_NAME = 'inv_series' THEN
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'series "%" cannot be deleted - deactivate it; it is part of the books.', OLD.series_code
                USING ERRCODE = 'PY019';
        END IF;
        IF NEW.series_code IS DISTINCT FROM OLD.series_code OR NEW.issuer_id IS DISTINCT FROM OLD.issuer_id
           OR NEW.kind IS DISTINCT FROM OLD.kind OR NEW.mode IS DISTINCT FROM OLD.mode
           OR NEW.prefix IS DISTINCT FROM OLD.prefix OR NEW.sep IS DISTINCT FROM OLD.sep
           OR NEW.width IS DISTINCT FROM OLD.width OR NEW.fy_reset IS DISTINCT FROM OLD.fy_reset THEN
            RAISE EXCEPTION 'series "%": its definition is immutable - create a new series instead.', OLD.series_code
                USING ERRCODE = 'PY019';
        END IF;
        RETURN NEW;
    ELSIF TG_TABLE_NAME = 'inv_series_counter' THEN
        IF TG_OP = 'DELETE' THEN
            IF OLD.last_number > 0 THEN
                RAISE EXCEPTION 'a series counter that has issued numbers cannot be deleted.' USING ERRCODE = 'PY019';
            END IF;
            RETURN OLD;
        END IF;
        IF NEW.series_id IS DISTINCT FROM OLD.series_id OR NEW.fy_label IS DISTINCT FROM OLD.fy_label THEN
            RAISE EXCEPTION 'the key of a series counter is immutable.' USING ERRCODE = 'PY019';
        END IF;
        IF NEW.last_number < OLD.last_number THEN
            RAISE EXCEPTION 'series counter % / "%" is at % and can never move backwards (asked for %).',
                OLD.series_id, OLD.fy_label, OLD.last_number, NEW.last_number USING ERRCODE = 'PY018';
        END IF;
        RETURN NEW;
    ELSE
        RAISE EXCEPTION 'inv_series_adoptions is append-only.' USING ERRCODE = 'PY019';
    END IF;
END;
$$ LANGUAGE plpgsql;
