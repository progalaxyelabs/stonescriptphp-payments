-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: tables :: wlt_packs (wallet v2)
--
-- A wallet PACK is what a customer buys: a named, priced item that grants an EXPLICIT number of credits. The credits are a property of the pack, not
-- derived from the amount paid at capture time, so there is no division at capture and nothing can fail to convert there (a GST-inclusive or a
-- discounted price is just a different price for the same credits). The price is the order's invoice spec; the library re-proves it at order creation.
--   credits_milli     the credits granted, in milli-credits (1000 = 1 credit by default), > 0
--   validity_*        how long a purchased credit lasts WHEN the expiry policy is on (pay_config 'wallet_expiry_enforced' = 1); NULL = no expiry
-- Created and validated by _wlt_pack_create (plan active, credits positive, validity pair). An order for a pack is refused unless the pack and its
-- plan are active (pay_order_create).
CREATE TABLE wlt_packs (
    id                BIGSERIAL PRIMARY KEY,
    pricing_plan_id   BIGINT NOT NULL REFERENCES pricing_plans(id),
    name              TEXT NOT NULL CHECK (btrim(name) <> ''),
    credits_milli     BIGINT NOT NULL CHECK (credits_milli > 0),
    validity_duration INTEGER CHECK (validity_duration IS NULL OR validity_duration > 0),
    validity_uom      TEXT CHECK (validity_uom IS NULL OR validity_uom IN ('day', 'month', 'year')),
    is_active         BOOLEAN NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        TEXT NOT NULL,
    CONSTRAINT wlt_packs_validity_pair CHECK ((validity_duration IS NULL) = (validity_uom IS NULL))
);
