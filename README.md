# NL Boundary Vintage Tracker

I built this pipeline to answer one question with evidence:

> **Are point observations assigned to the correct *vintage* of Dutch neighbourhood boundary?**

It loads several annual vintages of the CBS Wijk- en Buurtkaart into PostGIS, validates each
vintage as a topological coverage, and then measures how much a point's administrative
assignment changes depending on which vintage you join it to.

---

## 1. Data sources, licence and cost

**Everything here is free and publicly redistributable.** All verified July 2026.

| Dataset | Source | Format | Licence |
|---|---|---|---|
| Wijk- en Buurtkaart (2012–2025) | `geodata.cbs.nl` | Shapefile (older) / GeoPackage (newer) | Publication permitted with attribution to **CBS and Kadaster** |
| Wijk- en Buurtkaart (2021–2025) | PDOK WFS / WMS | GML, GeoJSON | Open data, CC0 or comparable; commercial use permitted |
| BAG (addresses & buildings) | PDOK Atom | GeoPackage | Open data, no cost |

### Direct download pattern (the archive — this is the one you want)

```
https://geodata.cbs.nl/files/Wijkenbuurtkaart/WijkBuurtkaart_<YEAR>_v<N>.zip
```

The `v<N>` revision suffix is **inconsistent across years** — 2025 is `v1`, 2024 is `v2`, and
2012–2023 are `v3`. `fetch_cbs.py` probes for the highest available revision rather than
hardcoding, so it keeps working when CBS republishes.

Verified available at time of writing: **2012, 2014–2023 (v3), 2024 (v2), 2025 (v1)**.

### PDOK (for recent vintages and for BAG)

```
https://service.pdok.nl/cbs/wijkenbuurten/<YEAR>/wfs/v1_0?request=GetCapabilities&service=WFS
https://service.pdok.nl/lv/bag/atom/bag.xml
```

PDOK only carries **2021 onwards**, so the historical depth this project needs has to come from
the CBS archive. Use PDOK when you want a live service rather than a bulk file.

### Attribution I carry into every output

I keep this line in the report footer and here in the README:

> Boundary data © CBS / Kadaster, Wijk- en Buurtkaart. Reused with attribution.

This matters commercially: a source's licence determines whether its data can go into a product,
so I keep the attribution attached to every derived output rather than treating it as an
afterthought.

---

## 2. What the data actually looks like

The schema changed between vintages, which is itself part of the problem being measured:

| | 2015 (and earlier) | 2025 (and recent) |
|---|---|---|
| Container | Shapefile in a subfolder | GeoPackage |
| Layers | `buurt_2015`, `wijk_2015`, `gem_2015` | `buurten`, `wijken`, `gemeenten` |
| Neighbourhood code | `BU_CODE` | `buurtcode` |
| Municipality code | `GM_CODE` | `gemeentecode` |
| Population | `AANT_INW` | `aantal_inwoners` |
| Change flag | `IND_WBI` | `indelingswijziging_wijken_en_buurten` |
| Geometry type | `Polygon` | `MultiPolygon` |
| Buurt count | 12,339 | 14,823 |
| CRS | EPSG:28992 | EPSG:28992 |

Two things worth noticing before you start:

- **The buurt count grew by 20% in ten years.** Some of that is new housing, but much of it is
  CBS re-cutting existing neighbourhoods. That is exactly the drift this pipeline quantifies.
- **CBS ships its own change flag** (`IND_WBI` / `indelingswijziging_wijken_en_buurten`). Use it
  as an independent check on your own results — if your detected changes and CBS's flag disagree,
  one of you is wrong and it is worth knowing which.

### The code structure invariant

A buurt code is `BU` + 4-digit gemeente + 2-digit wijk + 2-digit buurt (10 chars). A gemeente
code is `GM` + the same 4 digits (6 chars). So this must always hold:

```
'GM' || substring(buurtcode from 3 for 4) = gemeentecode
```

That is a genuine, checkable invariant, and it is why a municipal merger silently renumbers every
buurt inside it. Check C6 tests it.

---

## 3. Run order

```bash
python code/nl_boundaries/fetch_cbs.py --years 2015 2020 2025
```

```bash
python code/nl_boundaries/load_to_postgis.py --years 2015 2020 2025
```

Then, against your database:

| File | Purpose |
|---|---|
| `01_bootstrap.sql` | Schemas, helpers, harmonised `clean.buurten` / `clean.gemeenten` |
| `02_checks_coverage.sql` | C1–C6: is each vintage a valid coverage? |
| `03_checks_vintage.sql` | Tests A and B: is the point assignment right, and does vintage matter? |

Start with three vintages, not twenty. Three is enough to establish the curve.

---

## 4. The point layer, and the confidentiality boundary

Both the public and private runs use the same contract table:

```sql
clean.points(point_id, obs_year, geom, buurt_stored)
```

- **Public run (publishable):** BAG address points, or `--demo` synthetic points for a smoke test.
- **Private run (never publishable):** NVM transactions.

**NVM must not be published in any form that carries geometry.** A coordinate plus a price plus a
floor area plus a build year identifies a specific dwelling and household, which makes it personal
data under GDPR. From the NVM run you may publish **counts and rates only** — never per-record
points, and never a failure map where each dot is one house.

The pipeline is built so the swap is a single table load. Everything downstream is identical.

---

## 5. What the output is

`02` and `03` write result tables into the `qa` schema. Those are small, so they are safe to
commit and are what the Quarto report renders:

- `qa.coverage_results` — one row per check per vintage, with a pass/fail verdict
- `qa.vintage_disagreement` — disagreement rate by observation year (the headline chart)
- `qa.crosswalk` — old code → new code mapping, with a change classification

---

## Licence

The **code** in this repository is released under the [MIT License](LICENSE).

The **boundary data** is not mine to relicense: the CBS Wijk- en Buurtkaart is © CBS / Kadaster
and is reused under its own terms, which require attribution to CBS and Kadaster (see section 1).
