"""
Step 2 - Load, validate, reconcile, and publish.

  1. Loads every raw extract into SQLite exactly as received (all columns as TEXT).
  2. Runs sql/01..05 in order: reference data -> staging -> data-quality rules -> marts ->
     reconciliation.
  3. Adds the one rule that is easier to express outside SQL (schema drift across files).
  4. Exports results/*.csv and the dashboard data file docs/data.js.

Run:  python3 src/fetch.py && python3 src/pipeline.py
"""
import csv
import json
import re
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW, SQL, RESULTS, DOCS = ROOT / "data/raw", ROOT / "sql", ROOT / "results", ROOT / "docs"
DB = ROOT / "data" / "dfps.db"


def load_raw(con):
    for path in sorted(RAW.glob("*.csv")):
        with path.open(newline="") as f:
            rows = list(csv.reader(f))
        header, body = rows[0], rows[1:]
        table = f"raw_{path.stem}"
        cols = ", ".join(f'"{c}" TEXT' for c in header)
        con.execute(f"DROP TABLE IF EXISTS {table}")
        con.execute(f"CREATE TABLE {table} ({cols})")
        # Empty strings from the CSV are true nulls in the source API
        body = [[v if v != "" else None for v in r] for r in body]
        con.executemany(f"INSERT INTO {table} VALUES ({', '.join('?' * len(header))})", body)
        print(f"  loaded {table:<28} {len(body):>6} rows")


def schema_drift(con):
    """DQ-14: the same dataset family published with different column layouts."""
    manifest = json.loads((RAW / "manifest.json").read_text())
    exp = [s for s in manifest["sources"] if s["file"].startswith("exp_fy")]
    layouts = {}
    for s in exp:
        layouts.setdefault(tuple(s["columns"]), []).append(s["fiscal_year"])
    con.execute("""INSERT OR REPLACE INTO dq_rules VALUES ('DQ-14','Consistency',
        'Yearly extracts share one column layout','Warning',
        'Each layout mapped explicitly in sql/02_staging.sql')""")
    for cols, years in layouts.items():
        con.execute("INSERT INTO dq_results VALUES ('DQ-14', ?, ?, ?, NULL, ?)",
                    (min(years), len(exp), 0 if len(layouts) == 1 else len(years),
                     f"FY{', FY'.join(map(str, years))}: {', '.join(cols)}"))


def export(con, query, name):
    cur = con.execute(query)
    cols = [d[0] for d in cur.description]
    rows = cur.fetchall()
    with (RESULTS / f"{name}.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        w.writerows(rows)
    return [dict(zip(cols, r)) for r in rows]


def main():
    RESULTS.mkdir(exist_ok=True)
    DB.unlink(missing_ok=True)
    con = sqlite3.connect(DB)
    con.create_function("REGEXP", 2, lambda p, v: v is not None and re.search(p, v) is not None)
    print("Loading raw extracts:")
    load_raw(con)
    for f in sorted(SQL.glob("*.sql")):
        print(f"Running {f.name}")
        con.executescript(f.read_text())
        if f.name.startswith("03_"):
            schema_drift(con)
    con.commit()

    data = {}
    data["dq_summary"] = export(con, """
        SELECT r.rule_id, r.dimension, r.rule, r.severity, r.action,
               SUM(d.records_checked) records_checked, SUM(d.records_failed) records_failed,
               ROUND(SUM(d.dollars_affected), 2) dollars_affected,
               GROUP_CONCAT(CASE WHEN d.records_failed > 0 THEN 'FY' || d.fiscal_year END, ', ') years_affected
        FROM dq_rules r LEFT JOIN dq_results d USING (rule_id)
        GROUP BY r.rule_id ORDER BY r.rule_id""", "dq_summary")
    data["dq_detail"] = export(con, "SELECT * FROM dq_results ORDER BY rule_id, fiscal_year", "dq_detail")
    data["recon"] = export(con, "SELECT * FROM recon_results ORDER BY check_id, fiscal_year, breakdown", "reconciliation")
    data["trend"] = export(con, "SELECT * FROM mart_statewide_trend", "statewide_trend")
    data["region"] = export(con, "SELECT * FROM mart_region_year ORDER BY fiscal_year, region", "region_year")
    export(con, "SELECT * FROM mart_county_year ORDER BY fiscal_year, county", "county_year")
    export(con, "SELECT * FROM ref_county_alias", "business_rules_county_crosswalk")
    data["generated_from"] = json.loads((RAW / "manifest.json").read_text())["fetched_at_utc"]

    (DOCS / "data.js").write_text("window.DFPS_DATA = " + json.dumps(data, default=str) + ";\n")
    fails = con.execute("SELECT COUNT(*) FROM recon_results WHERE status = 'FAIL'").fetchone()[0]
    print(f"Done. Reconciliation checks failing: {fails}. Outputs in results/ and docs/data.js")


if __name__ == "__main__":
    main()
