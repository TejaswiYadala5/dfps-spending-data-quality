-- =====================================================================================
-- 05_reconciliation.sql
-- Control-total reconciliations. Each check compares two independent figures that should
-- agree, records the variance, and passes only when |variance| <= tolerance.
-- =====================================================================================

DROP TABLE IF EXISTS recon_results;
CREATE TABLE recon_results (
    check_id     TEXT,
    check_name   TEXT,
    fiscal_year  INTEGER,
    breakdown    TEXT,
    source_a     TEXT,
    amount_a     REAL,
    source_b     TEXT,
    amount_b     REAL,
    variance     REAL,
    tolerance    REAL,
    status       TEXT
);

-- REC-01  Pipeline completeness: every source dollar lands in the final fact table
--         (county-attributed + unattributed) - proves nothing was lost in transformation.
INSERT INTO recon_results
SELECT 'REC-01', 'Source file total vs. pipeline output', s.fiscal_year, 'All categories',
       'Raw extract (parsed)', s.amt, 'fact_expenditure (county + unattributed)', f.amt,
       ROUND(f.amt - s.amt, 2), 0.01, NULL
FROM (SELECT fiscal_year, SUM(amount) amt FROM stg_expenditure GROUP BY 1) s
JOIN (SELECT fiscal_year, SUM(amount) amt FROM fact_expenditure GROUP BY 1) f USING (fiscal_year);

-- REC-02  What a naive inner join to the county list would have lost (blank, misspelled,
--         or non-county values). Shows the dollars protected by the crosswalk rules.
INSERT INTO recon_results
SELECT 'REC-02', 'Dollars dropped by a naive county join (informational)', fiscal_year, 'All categories',
       'Raw extract (parsed)', SUM(amount),
       'Inner join to official county list', SUM(CASE WHEN attribution = 'County' THEN amount ELSE 0 END),
       ROUND(SUM(CASE WHEN attribution = 'County' THEN amount ELSE 0 END) - SUM(amount), 2), NULL, 'INFO'
FROM int_expenditure GROUP BY fiscal_year;

-- REC-03  Independent control total: Comptroller's FY2023 agency summary vs. FY2023 county
--         detail, by spending category.
INSERT INTO recon_results
SELECT 'REC-03', 'FY2023 Comptroller summary vs. county detail', 2023, d.cat,
       'County detail (exp_fy2023)', d.amt, 'Agency summary (exp_summary_2023)', s.amt,
       ROUND(s.amt - d.amt, 2), 1.00, NULL
FROM (SELECT UPPER(category_raw) cat, SUM(amount) amt FROM stg_expenditure
      WHERE source_file = 'exp_fy2023' GROUP BY 1) d
LEFT JOIN (SELECT UPPER(expenditure_category) cat,
                  SUM(CAST(REPLACE(amount, ',', '') AS REAL)) amt
           FROM raw_exp_summary_2023 GROUP BY 1) s USING (cat);

-- REC-04  FY2016 legacy layout: the published "total" column vs. the sum of its components.
INSERT INTO recon_results
SELECT 'REC-04', 'FY2016 published total column vs. sum of components', 2016, 'All counties',
       'Sum of 7 component columns', comp, 'Published total column', tot,
       ROUND(tot - comp, 2), 5.00, NULL
FROM (SELECT
        (SELECT SUM(amount) FROM stg_expenditure WHERE source_file = 'exp_fy2016') comp,
        (SELECT SUM(CAST(REPLACE(REPLACE(total, '$', ''), ',', '') AS REAL)) FROM raw_exp_fy2016) tot);

-- REC-05  Population: sum of 254 counties vs. the statewide 'All Counties' control row.
--         The control row publishes total population but leaves child population blank
--         (see DQ findings), so the check runs on total population.
INSERT INTO recon_results
SELECT 'REC-05', 'Total population: county sum vs. statewide control row', CAST(c.year AS INTEGER), 'All ages',
       'Sum of counties', c.s, 'All Counties row', CAST(t.total_population AS REAL),
       CAST(t.total_population AS REAL) - c.s, 0, NULL
FROM (SELECT year, SUM(CAST(total_population AS INTEGER)) s FROM raw_child_population
      WHERE county <> 'All Counties' GROUP BY year) c
JOIN raw_child_population t ON t.year = c.year AND t.county = 'All Counties';

UPDATE recon_results
SET status = CASE WHEN ABS(variance) <= tolerance THEN 'PASS' ELSE 'FAIL' END
WHERE status IS NULL;
