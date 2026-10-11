-- =====================================================================================
-- 01_reference.sql
-- Reference / master data: the official list of Texas counties and DFPS regions, plus the
-- crosswalks (business rules) used to standardize values that arrive from source systems.
-- =====================================================================================

-- Canonical county list = the 254 counties in the DFPS child population file.
-- 'All Counties' is a statewide control-total row, not a county, so it is excluded here
-- and used later as a reconciliation control.
DROP TABLE IF EXISTS ref_county;
CREATE TABLE ref_county AS
SELECT DISTINCT
    UPPER(TRIM(county))  AS county,
    county               AS county_display,
    region
FROM raw_child_population
WHERE county <> 'All Counties';

-- County-name crosswalk. Each row is a documented business rule: a value seen in a source
-- extract that does not match the reference list, and what it should resolve to.
-- canonical_county = NULL means "not a county -> treat as unattributed spending".
DROP TABLE IF EXISTS ref_county_alias;
CREATE TABLE ref_county_alias (
    raw_value        TEXT PRIMARY KEY,
    canonical_county TEXT,
    rule_note        TEXT
);
INSERT INTO ref_county_alias VALUES
  ('DE WITT', 'DEWITT',   'Spacing variant (FY2016 file)'),
  ('LASALLE', 'LA SALLE', 'Spelling changed in source system from FY2020 onward'),
  ('RAINES',  'RAINS',    'Misspelling present in source system from FY2020 onward'),
  ('INTEX',   NULL,       'Not a Texas county (FY2020 only); routed to unattributed');

-- Spending-category crosswalk. FY2016 was published in a legacy wide layout with 7 broad
-- "object" columns; FY2017+ use 12-14 detailed categories. Both map to 4 analysis groups so
-- the trend line is comparable. Professional services cannot be separated in FY2016.
DROP TABLE IF EXISTS ref_category;
CREATE TABLE ref_category (
    raw_category   TEXT PRIMARY KEY,
    category_group TEXT NOT NULL
);
INSERT INTO ref_category VALUES
  ('SALARIES AND WAGES',                 'Salaries & Benefits'),
  ('EMPLOYEE BENEFITS',                  'Salaries & Benefits'),
  ('PUBLIC ASSISTANCE PAYMENTS',         'Client Assistance Payments'),
  ('PROFESSIONAL SERVICE AND FEES',      'Professional Services & Fees'),
  ('CAPITAL OUTLAY',                     'Operations & Other'),
  ('CLAIMS AND JUDGMENTS',               'Operations & Other'),
  ('COMMUNICATIONS AND UTILITIES',       'Operations & Other'),
  ('OTHER EXPENDITURES',                 'Operations & Other'),
  ('PAYMENT OF INTEREST - DEBT SERVICE', 'Operations & Other'),
  ('PRINTING AND REPRODUCTION',          'Operations & Other'),
  ('RENTALS AND LEASES',                 'Operations & Other'),
  ('REPAIRS AND MAINTENANCE',            'Operations & Other'),
  ('SUPPLIES AND MATERIALS',             'Operations & Other'),
  ('TRAVEL',                             'Operations & Other'),
  -- FY2016 legacy wide-layout columns
  ('LABOR_COSTS',                        'Salaries & Benefits'),
  ('PUBLIC_ASSISTANCE',                  'Client Assistance Payments'),
  ('OPERATING_EXPENSES',                 'Operations & Other'),
  ('MISC',                               'Operations & Other'),
  ('CAPITAL_OUTLAYS',                    'Operations & Other'),
  ('INTERGOVERNMENTAL_PAYMENTS',         'Operations & Other'),
  ('HIGHWAY_CONSTRUCTION',               'Operations & Other');
