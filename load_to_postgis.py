#!/usr/bin/env python3
"""
Load CBS Wijk- en Buurtkaart vintages into PostGIS.

    export NL_DB_URL='postgresql://geo:geo@localhost:25432/nl'
    python code/nl_boundaries/load_to_postgis.py --years 2015 2020 2025
    python code/nl_boundaries/load_to_postgis.py --demo-points 20000

Creates, per vintage:
    raw.buurten_<YEAR>, raw.wijken_<YEAR>, raw.gemeenten_<YEAR>

`01_bootstrap.sql` then harmonises those into single `clean.buurten` / `clean.gemeenten`
tables with a `vintage` column.

WHY ogr2ogr AND NOT GEOPANDAS
-----------------------------
These files are 70-200 MB and the older ones are shapefiles. ogr2ogr streams straight from
inside the zip into PostGIS without ever holding the layer in memory, promotes Polygon to
MultiPolygon on the way in, and is the tool an employer expects you to reach for. GeoPandas
would read the whole thing into RAM to achieve the same result more slowly.

THE SCHEMA PROBLEM THIS HANDLES
-------------------------------
Older vintages are shapefiles in a subfolder with layers named buurt_<YEAR>, wijk_<YEAR>,
gem_<YEAR> and uppercase fields (BU_CODE, GM_CODE). Newer vintages are GeoPackages with layers
named buurten, wijken, gemeenten and lowercase descriptive fields (buurtcode, gemeentecode).
We detect which we are holding rather than assuming, because the cutover year is not documented
and CBS may move it again.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path

RAW_DIR = Path(os.environ.get(
    "NL_DATA_DIR",
    Path(__file__).resolve().parents[1] / "data" / "raw" / "cbs",
))

# Which CBS layer maps to which target table. Order matters only for readability.
LEVELS = {
    "buurten":   {"gpkg": "buurten",   "shp_prefix": "buurt"},
    "wijken":    {"gpkg": "wijken",    "shp_prefix": "wijk"},
    "gemeenten": {"gpkg": "gemeenten", "shp_prefix": "gem"},
}


def db_url() -> str:
    url = os.environ.get("NL_DB_URL") or os.environ.get("GEO_DB_URL")
    if not url:
        sys.exit("Set NL_DB_URL, e.g.\n"
                 "  export NL_DB_URL='postgresql://geo:geo@localhost:25432/nl'")
    # ogr2ogr wants a plain libpq URI, not the SQLAlchemy dialect prefix.
    return url.replace("postgresql+psycopg2://", "postgresql://", 1)


def ensure_database(url: str) -> None:
    """Create the PostGIS extension and target schemas.

    ogr2ogr will not create either for us: without the extension it cannot write a geometry
    column, and with -lco SCHEMA=raw it expects that schema to exist. Doing this here means a
    fresh database works on the first run instead of failing halfway through the first load.
    """
    try:
        import psycopg2
    except ImportError:
        print("  (psycopg2 not available; skipping extension/schema setup -- if the load "
              "fails, run 01_bootstrap.sql first)", file=sys.stderr)
        return
    with psycopg2.connect(url) as conn:
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute("CREATE EXTENSION IF NOT EXISTS postgis;")
            for schema in ("raw", "clean", "analysis", "qa"):
                cur.execute(f"CREATE SCHEMA IF NOT EXISTS {schema};")
    print("Database ready: postgis extension + raw/clean/analysis/qa schemas")


def find_zip(year: int, raw_dir: Path) -> Path:
    hits = sorted(raw_dir.glob(f"WijkBuurtkaart_{year}_v*.zip"))
    if not hits:
        sys.exit(f"No archive for {year} in {raw_dir}. Run fetch_cbs.py --years {year} first.")
    return hits[-1]          # highest revision if several are present


def describe(zip_path: Path, year: int) -> dict[str, str]:
    """Return {level: ogr dataset path} for this archive, detecting gpkg vs shapefile."""
    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()

    gpkgs = [n for n in names if n.lower().endswith(".gpkg")]
    if gpkgs:
        inner = gpkgs[0]
        return {lvl: f"/vsizip/{zip_path}/{inner}" for lvl in LEVELS}

    shps = [n for n in names if n.lower().endswith(".shp")]
    if not shps:
        sys.exit(f"{zip_path.name}: contains neither .gpkg nor .shp")

    out: dict[str, str] = {}
    for lvl, cfg in LEVELS.items():
        prefix = cfg["shp_prefix"]
        # e.g. WijkBuurtkaart_2015_v3/buurt_2015.shp
        match = [n for n in shps
                 if re.search(rf"/{prefix}_{year}\.shp$", n, re.IGNORECASE)
                 or re.search(rf"/{prefix}\.shp$", n, re.IGNORECASE)]
        if not match:
            print(f"  warning: no {prefix} layer found for {year}", file=sys.stderr)
            continue
        out[lvl] = f"/vsizip/{zip_path}/{match[0]}"
    return out


def layer_name(dataset: str, lvl: str, year: int) -> str | None:
    """GeoPackages need an explicit layer name; a single .shp does not."""
    if dataset.lower().endswith(".gpkg"):
        return LEVELS[lvl]["gpkg"]
    return None


def run_ogr(dataset: str, layer: str | None, target: str, url: str) -> None:
    cmd = [
        "ogr2ogr",
        "-f", "PostgreSQL", f"PG:{url}",
        dataset,
        "-nln", target,
        "-nlt", "PROMOTE_TO_MULTI",     # 2015 ships Polygon, 2025 ships MultiPolygon
        "-lco", "GEOMETRY_NAME=geom",
        "-lco", "SCHEMA=raw",
        "-lco", "SPATIAL_INDEX=GIST",
        "-a_srs", "EPSG:28992",         # all vintages are RD New; assert it rather than trust it
        "-overwrite",
        "-progress",
        "--config", "PG_USE_COPY", "YES",
    ]
    if layer:
        cmd.append(layer)
    print("  " + " ".join(cmd[:6]) + f" ... -nln {target}")
    res = subprocess.run(cmd)
    if res.returncode != 0:
        sys.exit(f"ogr2ogr failed for {target}")


def load_year(year: int, raw_dir: Path, url: str) -> None:
    zip_path = find_zip(year, raw_dir)
    print(f"\n{year}: {zip_path.name}")
    datasets = describe(zip_path, year)
    for lvl, dataset in datasets.items():
        target = f"{lvl}_{year}"        # SCHEMA=raw layer creation option puts it in raw
        run_ogr(dataset, layer_name(dataset, lvl, year), target, url)


DEMO_SQL = """
-- Synthetic points for smoke-testing the harness before real data arrives.
-- Samples random locations inside land buurten of the newest vintage and assigns each a
-- random observation year, so Test B produces a real curve rather than a flat line.
--
-- N is approximate: we spread it evenly over the buurten with a floor of one point each,
-- so the true count is max(N, number_of_land_buurten).
CREATE TABLE IF NOT EXISTS clean.points (
    point_id      bigint PRIMARY KEY,
    obs_year      int    NOT NULL,
    geom          geometry(Point, 28992) NOT NULL,
    buurt_stored  text
);

TRUNCATE clean.points;

INSERT INTO clean.points (point_id, obs_year, geom, buurt_stored)
WITH src AS (
    SELECT geom FROM clean.buurten
    WHERE vintage = (SELECT max(vintage) FROM clean.buurten)
      AND NOT is_water
),
pts AS (
    -- LATERAL rather than ST_Dump() in the target list. A set-returning function in the
    -- SELECT list expands each input row into many output rows, but window functions are
    -- evaluated BEFORE that expansion -- so row_number() would hand every point sampled
    -- from the same buurt an identical id, and the primary key would reject the insert.
    SELECT d.geom AS geom
    FROM src
    CROSS JOIN LATERAL ST_Dump(
        ST_GeneratePoints(
            src.geom,
            GREATEST(1, (%(n)s::numeric / (SELECT count(*) FROM src))::int)
        )
    ) AS d
)
SELECT row_number() OVER ()                 AS point_id,
       (2005 + floor(random() * 21))::int   AS obs_year,
       geom,
       NULL::text                           AS buurt_stored
FROM pts;

CREATE INDEX IF NOT EXISTS idx_points_geom ON clean.points USING GIST (geom);
ANALYZE clean.points;

-- Stamp each demo point with the newest-vintage code, mimicking a `buurt_nr_2022`-style
-- column that was populated once against a single vintage.
UPDATE clean.points p
SET buurt_stored = b.buurtcode
FROM clean.buurten b
WHERE b.vintage = (SELECT max(vintage) FROM clean.buurten)
  AND ST_Contains(b.geom, p.geom);
"""


def make_demo_points(n: int, url: str) -> None:
    try:
        import psycopg2
    except ImportError:
        sys.exit("--demo-points needs psycopg2:  conda activate geo")
    print(f"Generating ~{n} demo points ...")
    with psycopg2.connect(url) as conn, conn.cursor() as cur:
        cur.execute(DEMO_SQL, {"n": n})
        cur.execute("SELECT count(*) FROM clean.points")
        print(f"  clean.points: {cur.fetchone()[0]} rows")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--years", type=int, nargs="*", default=[])
    ap.add_argument("--raw", type=Path, default=RAW_DIR)
    ap.add_argument("--demo-points", type=int, metavar="N",
                    help="After loading, generate ~N synthetic points into clean.points.")
    args = ap.parse_args()

    url = db_url()

    if args.years:
        ensure_database(url)

    for year in sorted(set(args.years)):
        load_year(year, args.raw, url)

    if args.years:
        print("\nLoaded. Next: run 01_bootstrap.sql to build clean.buurten / clean.gemeenten.")

    if args.demo_points:
        make_demo_points(args.demo_points, url)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
