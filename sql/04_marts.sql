-- =====================================================================================
-- 04_marts.sql
-- Reporting tables: the cleaned fact table at the expected grain, and the summary marts
-- that feed the dashboard and findings. 05_reconciliation.sql then checks it.
-- =====================================================================================

-- Fact table at the expected grain: fiscal year x county (or unattributed bucket) x category.
-- FY2016 is excluded from the comparable trend (see DQ findings) but kept in the fact table
-- with scope_flag so it is never silently mixed in.
DROP TABLE IF EXISTS fact_expenditure;
CREATE TABLE fact_expenditure AS
SELECT fiscal_year,
       COALESCE(county, 'UNATTRIBUTED') AS county,
       COALESCE(region, 'Unattributed') AS region,
       CASE WHEN county IS NULL THEN 0 ELSE 1 END AS is_county,
       category_group,
       UPPER(category_raw) AS category,
       SUM(amount) AS amount,
       COUNT(*)    AS source_records,
       CASE WHEN fiscal_year = 2016 THEN 'Legacy scope - not comparable' ELSE 'Comparable' END AS scope_flag
FROM int_expenditure
GROUP BY 1, 2, 3, 4, 5, 6;

-- Statewide trend by category group
DROP TABLE IF EXISTS mart_statewide_trend;
CREATE TABLE mart_statewide_trend AS
SELECT fiscal_year, scope_flag,
       SUM(amount)                                                         AS total_spend,
       SUM(CASE WHEN is_county = 1 THEN amount ELSE 0 END)                 AS county_attributed,
       SUM(CASE WHEN is_county = 0 THEN amount ELSE 0 END)                 AS unattributed,
       SUM(CASE WHEN category_group = 'Salaries & Benefits' THEN amount ELSE 0 END)          AS salaries_benefits,
       SUM(CASE WHEN category_group = 'Client Assistance Payments' THEN amount ELSE 0 END)   AS client_assistance,
       SUM(CASE WHEN category_group = 'Professional Services & Fees' THEN amount ELSE 0 END) AS professional_services,
       SUM(CASE WHEN category_group = 'Operations & Other' THEN amount ELSE 0 END)           AS operations_other
FROM fact_expenditure GROUP BY 1, 2 ORDER BY 1;

-- County x year: spending joined to DFPS service volume
DROP TABLE IF EXISTS mart_county_year;
CREATE TABLE mart_county_year AS
SELECT s.fiscal_year, s.county_display AS county, s.region,
       COALESCE(e.spend, 0) AS attributed_spend,
       s.children_in_care, s.removals, s.confirmed_victims, s.alleged_victims,
       s.aps_investigations, s.child_population
FROM int_services s
LEFT JOIN (SELECT fiscal_year, county, SUM(amount) spend FROM fact_expenditure
           WHERE is_county = 1 GROUP BY 1, 2) e
       ON e.county = s.county AND e.fiscal_year = s.fiscal_year
WHERE s.fiscal_year BETWEEN 2017 AND 2024;

-- Region x year: unit-cost and rate metrics
DROP TABLE IF EXISTS mart_region_year;
CREATE TABLE mart_region_year AS
SELECT fiscal_year, region,
       SUM(attributed_spend)   AS attributed_spend,
       SUM(children_in_care)   AS children_in_care,
       SUM(removals)           AS removals,
       SUM(confirmed_victims)  AS confirmed_victims,
       SUM(alleged_victims)    AS alleged_victims,
       SUM(child_population)   AS child_population,
       ROUND(SUM(attributed_spend) / NULLIF(SUM(children_in_care), 0), 0)               AS spend_per_child_in_care,
       ROUND(1000.0 * SUM(confirmed_victims) / NULLIF(SUM(child_population), 0), 2)    AS confirmed_victims_per_1k,
       ROUND(100.0 * SUM(confirmed_victims) / NULLIF(SUM(alleged_victims), 0), 1)      AS confirmation_rate_pct
FROM mart_county_year
GROUP BY 1, 2;
