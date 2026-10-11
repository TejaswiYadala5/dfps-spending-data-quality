-- =====================================================================================
-- 02_staging.sql
-- Conform eight differently shaped yearly extracts into one long table with a single
-- layout. Raw values are carried alongside cleaned values so every transformation can be
-- audited row by row (source_file + source_row point back to the exact raw record).
-- =====================================================================================

DROP TABLE IF EXISTS stg_expenditure;
CREATE TABLE stg_expenditure (
    source_file   TEXT,
    source_row    INTEGER,
    file_label_fy INTEGER,   -- fiscal year in the dataset's title
    fiscal_year   INTEGER,   -- fiscal year on the record itself
    county_raw    TEXT,
    category_raw  TEXT,
    amount_raw    TEXT,
    amount        REAL
);

-- FY2016: legacy wide layout (one column per spending object), currency-formatted text
-- ("$1,389,709.00") and "-" used as a zero placeholder. Unpivot to long format.
INSERT INTO stg_expenditure (source_file, source_row, file_label_fy, fiscal_year, county_raw, category_raw, amount_raw)
SELECT 'exp_fy2016', rowid, 2016, 2016, county_name, 'LABOR_COSTS',                labor_costs                FROM raw_exp_fy2016 UNION ALL
SELECT 'exp_fy2016', rowid, 2016, 2016, county_name, 'PUBLIC_ASSISTANCE',          public_assistance          FROM raw_exp_fy2016 UNION ALL
SELECT 'exp_fy2016', rowid, 2016, 2016, county_name, 'OPERATING_EXPENSES',         operating_expenses         FROM raw_exp_fy2016 UNION ALL
SELECT 'exp_fy2016', rowid, 2016, 2016, county_name, 'MISC',                       misc                       FROM raw_exp_fy2016 UNION ALL
SELECT 'exp_fy2016', rowid, 2016, 2016, county_name, 'CAPITAL_OUTLAYS',            capital_outlays            FROM raw_exp_fy2016 UNION ALL
SELECT 'exp_fy2016', rowid, 2016, 2016, county_name, 'INTERGOVERNMENTAL_PAYMENTS', intergovernmental_payments FROM raw_exp_fy2016 UNION ALL
SELECT 'exp_fy2016', rowid, 2016, 2016, county_name, 'HIGHWAY_CONSTRUCTION',       highway_construction       FROM raw_exp_fy2016;

-- FY2018 file (also carries FY2017 records), FY2020-2022, FY2024: county / major_spending_category
INSERT INTO stg_expenditure (source_file, source_row, file_label_fy, fiscal_year, county_raw, category_raw, amount_raw)
SELECT 'exp_fy2018', rowid, 2018, CAST(fiscal_year AS INTEGER), county, major_spending_category, amount FROM raw_exp_fy2018 UNION ALL
SELECT 'exp_fy2020', rowid, 2020, CAST(fiscal_year AS INTEGER), county, major_spending_category, amount FROM raw_exp_fy2020 UNION ALL
SELECT 'exp_fy2021', rowid, 2021, CAST(fiscal_year AS INTEGER), county, major_spending_category, amount FROM raw_exp_fy2021 UNION ALL
SELECT 'exp_fy2022', rowid, 2022, CAST(fiscal_year AS INTEGER), county, major_spending_category, amount FROM raw_exp_fy2022 UNION ALL
SELECT 'exp_fy2024', rowid, 2024, CAST(fiscal_year AS INTEGER), county, major_spending_category, amount FROM raw_exp_fy2024;

-- FY2019: county column is named county_name, agency column is "agency"
INSERT INTO stg_expenditure (source_file, source_row, file_label_fy, fiscal_year, county_raw, category_raw, amount_raw)
SELECT 'exp_fy2019', rowid, 2019, CAST(fiscal_year AS INTEGER), county_name, major_spending_category, amount FROM raw_exp_fy2019;

-- FY2023: category column renamed to expenditure_category; amounts comma-formatted text
INSERT INTO stg_expenditure (source_file, source_row, file_label_fy, fiscal_year, county_raw, category_raw, amount_raw)
SELECT 'exp_fy2023', rowid, 2023, CAST(fiscal_year AS INTEGER), county, expenditure_category, amount FROM raw_exp_fy2023;

-- Standard amount cleaning: strip "$", spaces, and thousands separators; then "-" and blank
-- mean zero. (FY2016 uses two zero placeholders: "-" and "$ -".)
UPDATE stg_expenditure
SET amount = CASE
    WHEN amount_raw IS NULL THEN 0.0
    WHEN REPLACE(REPLACE(REPLACE(amount_raw, '$', ''), ',', ''), ' ', '') IN ('', '-') THEN 0.0
    WHEN REPLACE(REPLACE(REPLACE(amount_raw, '$', ''), ',', ''), ' ', '') REGEXP '^-?[0-9]+(\.[0-9]+)?$'
        THEN CAST(REPLACE(REPLACE(REPLACE(amount_raw, '$', ''), ',', ''), ' ', '') AS REAL)
    ELSE NULL   -- unparseable -> caught by rule DQ-04
END;

-- =====================================================================================
-- Conformed expenditure table: county standardized through the reference list and the
-- alias crosswalk; anything that is not a valid county becomes "Unattributed" rather than
-- being dropped, so dollars always reconcile to the source total.
-- =====================================================================================
DROP TABLE IF EXISTS int_expenditure;
CREATE TABLE int_expenditure AS
SELECT
    s.*,
    UPPER(TRIM(s.county_raw)) AS county_std,
    COALESCE(rc.county, ra.canonical_county) AS county,
    COALESCE(rc.region, rc2.region)          AS region,
    CASE
        WHEN s.county_raw IS NULL OR TRIM(s.county_raw) = ''           THEN 'Unattributed - blank county'
        WHEN rc.county IS NULL AND ra.raw_value IS NULL                 THEN 'Unattributed - unrecognized county'
        WHEN rc.county IS NULL AND ra.canonical_county IS NULL          THEN 'Unattributed - not a county'
        WHEN rc.county IS NULL                                          THEN 'County - via crosswalk'
        ELSE 'County'
    END AS attribution,
    COALESCE(cat.category_group, 'UNMAPPED') AS category_group
FROM stg_expenditure s
LEFT JOIN ref_county       rc  ON rc.county    = UPPER(TRIM(s.county_raw))
LEFT JOIN ref_county_alias ra  ON ra.raw_value = UPPER(TRIM(s.county_raw))
LEFT JOIN ref_county       rc2 ON rc2.county   = ra.canonical_county
LEFT JOIN ref_category     cat ON cat.raw_category = UPPER(TRIM(s.category_raw));

-- =====================================================================================
-- DFPS service-volume data, standardized to county x fiscal year.
-- =====================================================================================
DROP TABLE IF EXISTS int_services;
CREATE TABLE int_services AS
WITH removals AS (
    SELECT CAST(fiscal_year AS INTEGER) fy, UPPER(county) county, SUM(CAST(removals AS INTEGER)) removals
    FROM raw_cps_removals GROUP BY 1, 2),
victims AS (
    SELECT CAST(fiscal_year AS INTEGER) fy, UPPER(county) county,
           SUM(CASE WHEN confirmed_victims = 'Confirmed Victim' THEN CAST(victims AS INTEGER) ELSE 0 END) confirmed_victims,
           SUM(CAST(victims AS INTEGER)) alleged_victims
    FROM raw_cpi_victims GROUP BY 1, 2),
aps AS (
    SELECT CAST(fiscal_year AS INTEGER) fy, UPPER(county) county, SUM(CAST(completed_investigations AS INTEGER)) aps_investigations
    FROM raw_aps_investigations GROUP BY 1, 2),
served AS (
    SELECT CAST(fiscal_year AS INTEGER) fy, UPPER(county) county, SUM(CAST(children AS INTEGER)) children_in_care
    FROM raw_cps_children_served GROUP BY 1, 2),
pop AS (
    SELECT CAST(year AS INTEGER) fy, UPPER(county) county, CAST(child_population AS INTEGER) child_population
    FROM raw_child_population WHERE county <> 'All Counties')
SELECT c.county, c.county_display, c.region, y.fy AS fiscal_year,
       COALESCE(r.removals, 0)            AS removals,
       COALESCE(v.confirmed_victims, 0)   AS confirmed_victims,
       COALESCE(v.alleged_victims, 0)     AS alleged_victims,
       COALESCE(a.aps_investigations, 0)  AS aps_investigations,
       COALESCE(s.children_in_care, 0)    AS children_in_care,
       p.child_population
FROM ref_county c
CROSS JOIN (SELECT DISTINCT CAST(year AS INTEGER) fy FROM raw_child_population) y
LEFT JOIN removals r ON r.county = c.county AND r.fy = y.fy
LEFT JOIN victims  v ON v.county = c.county AND v.fy = y.fy
LEFT JOIN aps      a ON a.county = c.county AND a.fy = y.fy
LEFT JOIN served   s ON s.county = c.county AND s.fy = y.fy
LEFT JOIN pop      p ON p.county = c.county AND p.fy = y.fy;
