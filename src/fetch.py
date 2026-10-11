"""
Step 1 - Extract.

Pulls the public source data from the Texas Open Data Portal (data.texas.gov, Socrata API)
and saves each extract to data/raw/ exactly as received. Nothing is cleaned here: the raw
layer is kept untouched so every downstream number can be traced back to its source.

Sources
  Texas Comptroller - State Expenditures by County (one dataset per fiscal year)
  Texas Comptroller - State Expenditures by County Summary 2023 (agency-level control total)
  DFPS Data Book    - removals, investigations, children served, child population
"""
import csv
import json
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

BASE = "https://data.texas.gov/resource/{id}.json"
RAW = Path(__file__).resolve().parent.parent / "data" / "raw"
PAGE = 50000

# Comptroller expenditure files. The publisher changed the layout between years, so each
# entry records the column that identifies the agency in that year's file.
EXPENDITURE_SOURCES = {
    2016: ("w7z7-5uku", "agency_number = '530'"),
    2018: ("f2iw-dtqt", "agency_number = '530'"),
    2019: ("2x5x-m677", "agency = '530'"),
    2020: ("aact-g69n", "agency_number = '530'"),
    2021: ("tup7-smjg", "agency_number = '530'"),
    2022: ("xys8-xb33", "agency_number = '530'"),
    2023: ("iyey-5sid", "number = '530'"),
    2024: ("2zpi-yjjs", "agency_number = '530'"),
}

OTHER_SOURCES = {
    # Agency-level summary published separately from the county detail -> reconciliation control
    "exp_summary_2023": ("fnb3-hipf", {"$where": "agency_name like '%FAMILY%PROTECT%'"}),
    # DFPS Data Book, FY2016-2025
    "cps_removals": ("xmtn-e5c8", {}),
    "cpi_victims": ("v63e-6dss", {}),
    "aps_investigations": ("3zr8-huug", {}),
    "child_population": ("x5xb-idr6", {}),
    # Children in DFPS legal responsibility is published at demographic grain (100K+ rows);
    # aggregate server-side to county x year.
    "cps_children_served": ("v7mp-wh8p", {
        "$select": "fiscal_year, county, region, sum(sum_child_in_dfps) as children",
        "$group": "fiscal_year, county, region",
    }),
}


def soql(dataset_id, params):
    """Page through a Socrata dataset and return every row."""
    rows, offset = [], 0
    while True:
        q = dict(params, **{"$limit": PAGE, "$offset": offset})
        if "$order" not in q and "$group" not in q:
            q["$order"] = ":id"
        url = BASE.format(id=dataset_id) + "?" + urllib.parse.urlencode(q)
        for attempt in range(3):
            try:
                with urllib.request.urlopen(url, timeout=120) as r:
                    batch = json.load(r)
                break
            except Exception:
                if attempt == 2:
                    raise
                time.sleep(3)
        rows.extend(batch)
        if len(batch) < PAGE:
            return rows
        offset += PAGE


def save(name, dataset_id, rows):
    cols = sorted({k for r in rows for k in r})
    path = RAW / f"{name}.csv"
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    print(f"  {name:<28} {dataset_id}  {len(rows):>6} rows  {len(cols)} cols")
    return {"file": path.name, "dataset_id": dataset_id, "rows": len(rows), "columns": cols,
            "url": f"https://data.texas.gov/d/{dataset_id}"}


def main():
    RAW.mkdir(parents=True, exist_ok=True)
    manifest = {"fetched_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "sources": []}
    print("Comptroller expenditures (DFPS, agency 530):")
    for fy, (dsid, where) in EXPENDITURE_SOURCES.items():
        rows = soql(dsid, {"$where": where})
        manifest["sources"].append(dict(save(f"exp_fy{fy}", dsid, rows), fiscal_year=fy))
    print("Control totals and DFPS Data Book:")
    for name, (dsid, params) in OTHER_SOURCES.items():
        manifest["sources"].append(save(name, dsid, soql(dsid, params)))
    (RAW / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"Wrote manifest with {len(manifest['sources'])} sources.")


if __name__ == "__main__":
    main()
