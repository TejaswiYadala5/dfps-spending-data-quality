# DFPS Spending vs. Services: Data Quality & Reconciliation Pipeline

**Live dashboard:** https://tejaswiyadala5.github.io/dfps-spending-data-quality/

A SQL pipeline that integrates nine years (FY2016–FY2024) of public Texas Comptroller expenditure
data for the **Texas Department of Family and Protective Services (DFPS)** with DFPS Data Book service
volumes. It applies 15 documented data-quality rules and checks with 32 control-total reconciliations
that every dollar matches its source. Analysis is reported only after those checks pass.

I built it to show, using DFPS's own public data, the work described in the **DFPS Data Analyst IV**
posting (#22131, Office of Finance, Financial Data Team).

> Independent portfolio project. Uses only public, aggregate data from [data.texas.gov](https://data.texas.gov).
> Not affiliated with or endorsed by DFPS or the Texas Comptroller. No confidential or case-level data is used.

---

## How this project connects to the Data Analyst IV role

The posting describes a role that writes SQL to compile financial reports, **owns data quality**
(standards, business rules, validation, reconciliation, quality metrics), integrates data across
financial and operational systems, and explains results to non-technical staff. Each of those
duties maps to a specific, runnable part of this repo:

| Posting requirement | Where it is demonstrated |
|---|---|
| **Experience writing and maintaining SQL scripts** (initial screening) | `sql/01`–`05`: ~490 lines of SQL covering reference data, staging, rules, marts and reconciliation, run in order by `src/pipeline.py` |
| **Experience analyzing financial data** (initial screening) | $18.8B of DFPS expenditures across 14 spending categories and 9 fiscal years (FY2016–FY2024) |
| **Power BI or Tableau visualizations** (preferred) | `docs/index.html`, a published dashboard. The CSVs in `results/` are ready to load into Power BI or Tableau |
| "Writes, extracts, queries, and compiles data to prepare **financial reports**" | `mart_statewide_trend` and `mart_region_year`: spending by category, year, region and county |
| "**Establishing standards, business rules, and quality controls**" | `sql/01_reference.sql`: county and category crosswalks, each a documented business rule with a reason |
| "Leads data quality activities by evaluating **completeness, accuracy, consistency, and reliability** across multiple systems" | `sql/03_data_quality.sql`: 15 rules tagged by dimension (completeness, validity, consistency, uniqueness, accuracy) and run for every fiscal year |
| "Develops and implements **data validation and reconciliation** processes that support **root cause analysis** and corrective actions" | `sql/05_reconciliation.sql`: 5 control checks (32 comparisons). Each finding below records its root cause and the action taken |
| "Establish and maintain **quality metrics**, measures against results" | `results/dq_summary.csv` / `dq_detail.csv`: rows checked, rows failing and dollars affected, per rule per year |
| "Supports **data integration** between financial, operational, and reporting systems" | Joins Comptroller financial data to DFPS operational data (removals, investigations, children in care) at county × year |
| "Evaluates the impact of **system changes** on data structures, reporting, interfaces, and downstream processes" | DQ-14 (5 different layouts across 8 years) and DQ-02 (county spellings changed in the source system in FY2020). Both are shown to break a naive downstream join |
| "Being responsive to **open records requests and audit inquiries**" | Every output row traces back through `source_file` + `source_row` to the raw record, and raw extracts are kept unmodified with a fetch manifest |
| "**Creating and maintaining technical documentation**" | This README, inline SQL comments, and `results/business_rules_county_crosswalk.csv` |
| "**Presenting complex information to non-technical audiences**" / "recommends **visualization best practices**" | Each dashboard chart leads with a plain-language finding and a caveat about what the number can and cannot support |
| WCAG 2.1 AA / Section 508 accessibility (Additional Information) | Every chart has a text alternative and an expandable data table, colors meet AA contrast, and the page follows the system light or dark setting |

---

## Key findings

**Data quality (what the pipeline caught)**

1. **The source system changed county spellings in FY2020.** `LA SALLE` became `LASALLE` and `RAINS` became
   `RAINES`, and a non-county code `INTEX` appeared. A naive join to the official county list would silently
   drop those counties from FY2020 onward. A documented crosswalk resolves them (DQ-02, $5.2M across 6 years).
2. **Spending with no county recorded grew from 4.4% to 13.1%** ($83M in FY2017 → $324M in FY2024). The
   pipeline keeps this as "Unattributed" instead of dropping it, so totals still reconcile. A naive county join
   would understate FY2024 spending by **$325M** (REC-02).
3. **The file titled "2018" also contains every FY2017 record.** Reading records by their own fiscal year
   recovers FY2017 ($1.90B), which has no separate published file (DQ-06).
4. **FY2016 is not comparable to later years.** It uses a legacy layout, has no unattributed spending, leaves
   40 counties with no spending, and lists ARCHER, HOPKINS and YOAKUM twice with different amounts. It is kept
   but flagged and excluded from trends, pending confirmation from the source (DQ-11, DQ-15).
5. **Formats change from year to year.** FY2016 uses `$1,389,709.00` with two zero placeholders (`-` and `$ -`),
   FY2023 uses comma-formatted text, and FY2020 is published at a finer grain (up to 20 rows per county ×
   category). All are standardized by explicit rules (DQ-03, DQ-05, DQ-08).
6. **The statewide "All Counties" control row in the DFPS population file leaves child population blank.**
   The reconciliation therefore runs on total population, which ties out exactly (REC-05).

**Reconciliation:** 32 of 32 control comparisons pass. Pipeline output equals source to the cent for every
year (REC-01). FY2023 county detail equals the Comptroller's separately published agency summary in all 12
categories (REC-03).

**Analysis (FY2017 → FY2024)**

- DFPS expenditures grew **31%** ($1.90B → $2.48B), mostly from client assistance payments ($885M → $1,252M).
- Over the same period, children in DFPS legal responsibility fell **44%** (50,291 → 28,008). APS
  investigations stayed flat at about 85K per year, so spending is not tracking foster-care volume alone.
- County-attributed spending per child in care varies about **4×** by region (Abilene ~$33K, Houston ~$138K
  in FY2024). The likely cause is *where payments are recorded* (for example, a contractor's location) rather
  than a true cost difference. **I would not report this as unit cost** without first validating payment
  attribution with the finance team. That caveat is the main point of the finding.

---

## Pipeline

```
data.texas.gov (Socrata API)
        │  src/fetch.py           14 extracts saved unmodified + manifest.json (dataset IDs, columns, timestamp)
        ▼
  raw_* tables (SQLite, all TEXT)  src/pipeline.py loads the raw layer as received
        │
        ├─ sql/01_reference.sql      official county list, county + category crosswalks (business rules)
        ├─ sql/02_staging.sql        conform 5 layouts → one long table; clean amounts; keep raw beside clean
        ├─ sql/03_data_quality.sql   15 rules → dq_results (rows checked / failed / $ affected per year)
        ├─ sql/04_marts.sql          fact_expenditure + reporting marts (statewide, region, county × year)
        └─ sql/05_reconciliation.sql 5 control checks → recon_results (PASS / FAIL against tolerance)
        ▼
  results/*.csv  +  docs/data.js → docs/index.html (dashboard)
```

### Data sources

| Source | Dataset | Years |
|---|---|---|
| Comptroller: State Expenditures by County (agency 530, DFPS) | `w7z7-5uku`, `f2iw-dtqt`, `2x5x-m677`, `aact-g69n`, `tup7-smjg`, `xys8-xb33`, `iyey-5sid`, `2zpi-yjjs` | FY2016–FY2024 |
| Comptroller: State Expenditures by County Summary 2023 (control total) | `fnb3-hipf` | FY2023 |
| DFPS: CPS 2.1 Removals by County | `xmtn-e5c8` | FY2016–FY2025 |
| DFPS: CPI 3.8 Alleged and Confirmed Victims by County | `v63e-6dss` | FY2016–FY2025 |
| DFPS: APS 3.1 Investigations by County | `3zr8-huug` | FY2016–FY2025 |
| DFPS: CPS 2.3 Children in DFPS Legal Responsibility | `v7mp-wh8p` | FY2016–FY2025 |
| DFPS: CPI 1.1 Texas Child Population by County | `x5xb-idr6` | 2016–2025 |

Each dataset can be viewed at `https://data.texas.gov/d/<dataset id>`.

### Data-quality rules

| Rule | Dimension | Check | Action |
|---|---|---|---|
| DQ-01 | Completeness | County populated | Kept as "Unattributed", never dropped |
| DQ-02 | Validity | County on official Texas list | Crosswalk; non-counties → Unattributed |
| DQ-03 | Validity | Plain numeric amount format | Strip `$`, spaces, thousands separators |
| DQ-04 | Validity | Amount parseable after cleaning | Would block load |
| DQ-05 | Validity | Placeholder `-` / `$ -` instead of number | Treated as 0 |
| DQ-06 | Consistency | Record FY matches file's FY | Re-assign to record's own FY |
| DQ-07 | Validity | Category maps to an analysis group | Would block load |
| DQ-08 | Uniqueness | One row per county × category × FY | Aggregate to expected grain |
| DQ-09 | Uniqueness | No identical duplicate rows | Kept (grain not unique → may be legitimate) |
| DQ-10 | Accuracy | Non-negative amount | Kept (reversals/refunds net against spend) |
| DQ-11 | Completeness | Every county has spending | Reported |
| DQ-12 | Consistency | Service records map to a Texas county | Out of State / Unknown kept out of county metrics |
| DQ-13 | Completeness | Child population populated | Per-capita rates NULL if missing |
| DQ-14 | Consistency | One column layout across years | Each layout mapped explicitly |
| DQ-15 | Uniqueness | One row per county in FY2016 layout | Flagged for source confirmation |

### Reconciliation controls

| Check | Compares | Tolerance | Result |
|---|---|---|---|
| REC-01 | Raw source total vs. pipeline output, per year | $0.01 | 9/9 PASS |
| REC-02 | Raw total vs. naive inner join to county list | informational | shows $83M–$325M/yr at risk |
| REC-03 | FY2023 county detail vs. Comptroller agency summary, per category | $1.00 | 12/12 PASS |
| REC-04 | FY2016 published total column vs. sum of components | $5.00 | PASS ($3 rounding) |
| REC-05 | County population sum vs. statewide control row | 0 | 10/10 PASS |

---

## Run it

Requires Python 3.9+ and nothing else (standard library only: `urllib`, `sqlite3`, `csv`, `json`).

```bash
python3 src/fetch.py      # pull fresh extracts from data.texas.gov into data/raw/
python3 src/pipeline.py   # build data/dfps.db, run all SQL, write results/ and docs/data.js
open docs/index.html      # view the dashboard locally
```

To explore the database directly: `sqlite3 data/dfps.db "SELECT * FROM dq_results WHERE records_failed > 0;"`

## Repository layout

```
src/fetch.py               extract from Socrata API → data/raw/ (+ manifest.json)
src/pipeline.py            load raw → run sql/ → export results/ and docs/data.js
sql/01_reference.sql       reference data and business-rule crosswalks
sql/02_staging.sql         conform layouts, clean amounts, standardize counties
sql/03_data_quality.sql    15 data-quality rules
sql/04_marts.sql           fact table and reporting marts
sql/05_reconciliation.sql  control-total reconciliations
results/                   dq_summary, dq_detail, reconciliation, statewide_trend, region_year,
                           county_year, business_rules_county_crosswalk (CSV, Power BI/Tableau-ready)
docs/index.html            accessible dashboard (GitHub Pages)
```

## Limitations

- The Comptroller's county reflects where a payment is attributed, not necessarily where services were delivered.
- Spending covers all DFPS programs, so the "per child in care" figure is an indicator for discussion, not a unit cost.
- Public data is aggregated. Internal sources such as CAPPS Financials and PeopleSoft would allow
  transaction-level reconciliation (for example to the Monthly Financial Report or SEFA). This project applies
  the same methods to the most detailed data available publicly.

---

**Tejaswi Yadala** · [tejaswiyadala10@gmail.com](mailto:tejaswiyadala10@gmail.com) ·
[LinkedIn](https://www.linkedin.com/in/tejaswi-y-82068b205/)
