-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: seeders :: inv_gst_state_codes — split from Gst/025_gst_state_codes.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: CBIC GST state/UT codes — PORT of `Support/GstStateCodes.php`
--
-- The state-code table is DATA, not code (the "every VALUE is DATA" principle).
-- Two tables: the canonical code->name set, and the accepted name aliases
-- (lowercase, incl. common spelling/punctuation variants) -> code. Functions carry
-- only the lookup FORMULA. `resolve()` returns NULL (never a guess) for an
-- unassigned 2-digit code ('00','28','92','99') or an unrecognised name.

-- 01-38 state/UT range (28 deliberately ABSENT — discontinued, merged into 26),
-- plus the two special place-of-supply codes 96/97 (confirmed per review W3).
-- 99 (OIDAR) deliberately left out.

INSERT INTO inv_gst_state_codes (code, canonical_name) VALUES
    ('01','Jammu and Kashmir'), ('02','Himachal Pradesh'), ('03','Punjab'),
    ('04','Chandigarh'), ('05','Uttarakhand'), ('06','Haryana'), ('07','Delhi'),
    ('08','Rajasthan'), ('09','Uttar Pradesh'), ('10','Bihar'), ('11','Sikkim'),
    ('12','Arunachal Pradesh'), ('13','Nagaland'), ('14','Manipur'), ('15','Mizoram'),
    ('16','Tripura'), ('17','Meghalaya'), ('18','Assam'), ('19','West Bengal'),
    ('20','Jharkhand'), ('21','Odisha'), ('22','Chhattisgarh'), ('23','Madhya Pradesh'),
    ('24','Gujarat'), ('25','Daman and Diu'),
    ('26','Dadra and Nagar Haveli and Daman and Diu'),
    ('27','Maharashtra'), ('29','Karnataka'), ('30','Goa'), ('31','Lakshadweep'),
    ('32','Kerala'), ('33','Tamil Nadu'), ('34','Puducherry'),
    ('35','Andaman and Nicobar Islands'), ('36','Telangana'), ('37','Andhra Pradesh'),
    ('38','Ladakh'), ('96','Other Country'), ('97','Other Territory');
