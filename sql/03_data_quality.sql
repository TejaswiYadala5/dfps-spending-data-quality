-- =====================================================================================
-- 03_data_quality.sql
-- Data-quality rule engine. Every rule writes one row per fiscal year to dq_results with
-- the records checked, records failing, dollars affected, and the action taken. Rules are
-- grouped by the standard data-quality dimensions: completeness, validity, consistency,
-- uniqueness, and accuracy.
-- =====================================================================================

DROP TABLE IF EXISTS dq_rules;
CREATE TABLE dq_rules (
    rule_id   TEXT PRIMARY KEY,
    dimension TEXT,
    rule      TEXT,
    severity  TEXT,     -- Critical = would misstate totals if unhandled; Warning = review; Info = documented
    action    TEXT
);
INSERT INTO dq_rules VALUES
 ('DQ-01','Completeness','County is populated on every expenditure record','Warning',
  'Kept and reported as "Unattributed"; never dropped'),
 ('DQ-02','Validity','County matches the official Texas county list','Critical',
  'Resolved through ref_county_alias crosswalk; non-counties routed to Unattributed'),
 ('DQ-03','Validity','Amount uses plain numeric format','Info',
  'Standardized: stripped "$" and thousands separators'),
 ('DQ-04','Validity','Amount is parseable after standard cleaning','Critical',
  'Would block load; none found'),
 ('DQ-05','Validity','Placeholder ("-" or "$ -") used instead of a number','Info',
  'Treated as 0 per source convention'),
 ('DQ-06','Consistency','Fiscal year on record matches the fiscal year in the file title','Warning',
  'Records re-assigned to their own fiscal year (recovers FY2017)'),
 ('DQ-07','Validity','Spending category maps to an analysis group','Critical',
  'Unmapped categories would be flagged; none found'),
 ('DQ-08','Uniqueness','One record per county x category x fiscal year (expected grain)','Warning',
  'Aggregated to expected grain; amounts summed'),
 ('DQ-09','Uniqueness','No fully identical duplicate records','Warning',
  'Kept: grain is not unique in source, so identical rows can be legitimate split payments'),
 ('DQ-10','Accuracy','Amount is non-negative','Warning',
  'Kept: negative amounts are reversals/refunds and net against spending'),
 ('DQ-11','Completeness','Every Texas county has DFPS spending recorded in the year','Info',
  'Reported; county shown with $0 attributed spending'),
 ('DQ-12','Consistency','Service-data records map to a Texas county','Info',
  'Out of State / Unknown records excluded from county metrics, retained in statewide totals'),
 ('DQ-13','Completeness','Child population is populated for every county-year','Warning',
  'Per-capita rates set to NULL where population missing'),
 ('DQ-15','Uniqueness','A file published at one row per county contains each county once (FY2016)','Critical',
  'Kept and summed; flagged for source confirmation - may be mis-keyed counties');

DROP TABLE IF EXISTS dq_results;
CREATE TABLE dq_results (
    rule_id         TEXT,
    fiscal_year     INTEGER,
    records_checked INTEGER,
    records_failed  INTEGER,
    dollars_affected REAL,
    detail          TEXT
);

-- DQ-01 blank county
INSERT INTO dq_results
SELECT 'DQ-01', fiscal_year, COUNT(*),
       SUM(attribution = 'Unattributed - blank county'),
       SUM(CASE WHEN attribution = 'Unattributed - blank county' THEN amount ELSE 0 END), NULL
FROM int_expenditure GROUP BY fiscal_year;

-- DQ-02 county not on official list (before crosswalk)
INSERT INTO dq_results
SELECT 'DQ-02', fiscal_year, COUNT(*),
       SUM(attribution IN ('County - via crosswalk','Unattributed - not a county','Unattributed - unrecognized county')),
       SUM(CASE WHEN attribution IN ('County - via crosswalk','Unattributed - not a county','Unattributed - unrecognized county') THEN amount ELSE 0 END),
       (SELECT GROUP_CONCAT(v, ', ') FROM (SELECT DISTINCT county_std v FROM int_expenditure i2
          WHERE i2.fiscal_year = i.fiscal_year
            AND i2.attribution IN ('County - via crosswalk','Unattributed - not a county','Unattributed - unrecognized county')))
FROM int_expenditure i GROUP BY fiscal_year;

-- DQ-03 currency formatting present
INSERT INTO dq_results
SELECT 'DQ-03', fiscal_year, COUNT(*),
       SUM(amount_raw LIKE '%$%' OR amount_raw LIKE '%,%'), NULL, NULL
FROM int_expenditure GROUP BY fiscal_year;

-- DQ-04 unparseable amount
INSERT INTO dq_results
SELECT 'DQ-04', fiscal_year, COUNT(*), SUM(amount IS NULL), NULL, NULL
FROM int_expenditure GROUP BY fiscal_year;

-- DQ-05 placeholder "-"
INSERT INTO dq_results
SELECT 'DQ-05', fiscal_year, COUNT(*), SUM(REPLACE(REPLACE(amount_raw, '$', ''), ' ', '') = '-'), NULL, NULL
FROM int_expenditure GROUP BY fiscal_year;

-- DQ-06 record FY differs from file label
INSERT INTO dq_results
SELECT 'DQ-06', fiscal_year, COUNT(*), SUM(fiscal_year <> file_label_fy),
       SUM(CASE WHEN fiscal_year <> file_label_fy THEN amount ELSE 0 END),
       (SELECT GROUP_CONCAT(DISTINCT source_file) FROM int_expenditure i2
         WHERE i2.fiscal_year = i.fiscal_year AND i2.fiscal_year <> i2.file_label_fy)
FROM int_expenditure i GROUP BY fiscal_year;

-- DQ-07 unmapped category
INSERT INTO dq_results
SELECT 'DQ-07', fiscal_year, COUNT(*), SUM(category_group = 'UNMAPPED'),
       SUM(CASE WHEN category_group = 'UNMAPPED' THEN amount ELSE 0 END), NULL
FROM int_expenditure GROUP BY fiscal_year;

-- DQ-08 grain violations: rows that share county x category x FY with other rows
INSERT INTO dq_results
SELECT 'DQ-08', fiscal_year, SUM(n), SUM(CASE WHEN n > 1 THEN n ELSE 0 END),
       SUM(CASE WHEN n > 1 THEN amt ELSE 0 END),
       'max rows in one group: ' || MAX(n)
FROM (SELECT fiscal_year, COALESCE(county, attribution) k, category_raw, COUNT(*) n, SUM(amount) amt
      FROM int_expenditure WHERE source_file <> 'exp_fy2016'
      GROUP BY 1, 2, 3)
GROUP BY fiscal_year;

-- DQ-09 exact duplicates
INSERT INTO dq_results
SELECT 'DQ-09', fiscal_year, SUM(n), SUM(CASE WHEN n > 1 THEN n - 1 ELSE 0 END),
       SUM(CASE WHEN n > 1 THEN (n - 1) * amount ELSE 0 END), NULL
FROM (SELECT fiscal_year, county_raw, category_raw, amount_raw, amount, COUNT(*) n
      FROM int_expenditure WHERE source_file <> 'exp_fy2016' GROUP BY 1, 2, 3, 4)
GROUP BY fiscal_year;

-- DQ-10 negative amounts
INSERT INTO dq_results
SELECT 'DQ-10', fiscal_year, COUNT(*), SUM(amount < 0),
       SUM(CASE WHEN amount < 0 THEN amount ELSE 0 END), NULL
FROM int_expenditure GROUP BY fiscal_year;

-- DQ-11 counties with no attributed spending
INSERT INTO dq_results
SELECT 'DQ-11', y.fiscal_year, (SELECT COUNT(*) FROM ref_county),
       (SELECT COUNT(*) FROM ref_county c WHERE NOT EXISTS (
            SELECT 1 FROM int_expenditure i WHERE i.county = c.county AND i.fiscal_year = y.fiscal_year AND i.amount <> 0)),
       NULL,
       (SELECT GROUP_CONCAT(county_display, ', ') FROM ref_county c WHERE NOT EXISTS (
            SELECT 1 FROM int_expenditure i WHERE i.county = c.county AND i.fiscal_year = y.fiscal_year AND i.amount <> 0))
FROM (SELECT DISTINCT fiscal_year FROM int_expenditure) y;

-- DQ-12 service records without a Texas county (all four DFPS service files)
INSERT INTO dq_results
SELECT 'DQ-12', fy, SUM(n), SUM(CASE WHEN ok = 0 THEN n ELSE 0 END), NULL,
       GROUP_CONCAT(CASE WHEN ok = 0 THEN src || ': ' || county END, '; ')
FROM (
  SELECT 'removals' src, CAST(fiscal_year AS INTEGER) fy, county,
         UPPER(county) IN (SELECT county FROM ref_county) ok, COUNT(*) n
  FROM raw_cps_removals GROUP BY 1, 2, 3
  UNION ALL
  SELECT 'CPI victims', CAST(fiscal_year AS INTEGER), county, UPPER(county) IN (SELECT county FROM ref_county), COUNT(*)
  FROM raw_cpi_victims GROUP BY 1, 2, 3
  UNION ALL
  SELECT 'APS investigations', CAST(fiscal_year AS INTEGER), county, UPPER(county) IN (SELECT county FROM ref_county), COUNT(*)
  FROM raw_aps_investigations GROUP BY 1, 2, 3
  UNION ALL
  SELECT 'children in care', CAST(fiscal_year AS INTEGER), county, UPPER(county) IN (SELECT county FROM ref_county), COUNT(*)
  FROM raw_cps_children_served GROUP BY 1, 2, 3)
GROUP BY fy;

-- DQ-13 missing child population
INSERT INTO dq_results
SELECT 'DQ-13', CAST(year AS INTEGER), COUNT(*),
       SUM(child_population IS NULL OR TRIM(child_population) = ''), NULL,
       GROUP_CONCAT(CASE WHEN child_population IS NULL OR TRIM(child_population) = '' THEN county END, ', ')
FROM raw_child_population WHERE county <> 'All Counties'
GROUP BY 2;

-- DQ-15 FY2016 county repeated in a one-row-per-county layout
INSERT INTO dq_results
SELECT 'DQ-15', 2016, (SELECT COUNT(*) FROM raw_exp_fy2016),
       COALESCE(SUM(n), 0),
       (SELECT SUM(CAST(REPLACE(REPLACE(total, '$', ''), ',', '') AS REAL)) FROM raw_exp_fy2016
         WHERE county_name IN (SELECT county_name FROM raw_exp_fy2016 GROUP BY 1 HAVING COUNT(*) > 1)),
       GROUP_CONCAT(county_name || ' x' || n, ', ')
FROM (SELECT county_name, COUNT(*) n FROM raw_exp_fy2016 GROUP BY 1 HAVING COUNT(*) > 1);
