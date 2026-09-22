-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: seeders :: inv_gst_state_name_aliases — split from Gst/025_gst_state_codes.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: CBIC GST state/UT codes — PORT of `Support/GstStateCodes.php`
--
-- The state-code table is DATA, not code (the "every VALUE is DATA" principle).
-- Two tables: the canonical code->name set, and the accepted name aliases
-- (lowercase, incl. common spelling/punctuation variants) -> code. Functions carry
-- only the lookup FORMULA. `resolve()` returns NULL (never a guess) for an
-- unassigned 2-digit code ('00','28','92','99') or an unrecognised name.

INSERT INTO inv_gst_state_name_aliases (alias, code) VALUES
    ('jammu and kashmir','01'), ('jammu & kashmir','01'), ('jammu kashmir','01'),
    ('himachal pradesh','02'),
    ('punjab','03'),
    ('chandigarh','04'),
    ('uttarakhand','05'), ('uttaranchal','05'),
    ('haryana','06'),
    ('delhi','07'), ('nct of delhi','07'), ('new delhi','07'),
    ('rajasthan','08'),
    ('uttar pradesh','09'),
    ('bihar','10'),
    ('sikkim','11'),
    ('arunachal pradesh','12'),
    ('nagaland','13'),
    ('manipur','14'),
    ('mizoram','15'),
    ('tripura','16'),
    ('meghalaya','17'),
    ('assam','18'),
    ('west bengal','19'),
    ('jharkhand','20'),
    ('odisha','21'), ('orissa','21'),
    ('chhattisgarh','22'), ('chattisgarh','22'),
    ('madhya pradesh','23'),
    ('gujarat','24'),
    ('daman and diu','25'), ('daman & diu','25'),
    ('dadra and nagar haveli','26'), ('dadra & nagar haveli','26'),
    ('dadra and nagar haveli and daman and diu','26'),
    ('maharashtra','27'),
    ('karnataka','29'), ('karnataka (old)','29'),
    ('goa','30'),
    ('lakshadweep','31'),
    ('kerala','32'),
    ('tamil nadu','33'),
    ('puducherry','34'), ('pondicherry','34'),
    ('andaman and nicobar islands','35'), ('andaman & nicobar islands','35'),
    ('andaman and nicobar','35'),
    ('telangana','36'),
    ('andhra pradesh','37'),
    ('ladakh','38'),
    ('other country','96'), ('outside india','96'),
    ('other territory','97');
