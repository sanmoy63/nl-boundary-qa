# NL Boundary Vintage QA — Concept Walkthrough

A guided tour of what this pipeline does and, more importantly, *why each piece is there*.
Written to be read top to bottom once, then used as a reference. It assumes you think in data
and statistics but are newer to the production spatial-database stack.

The running example throughout is the project's real question:

> **Are point observations assigned to the correct *vintage* of Dutch neighbourhood boundary?**

---

## 0. The mental model

Everything below is one pipeline with six stages. Hold this shape in your head; each later
section zooms into one box.

```
  fetch            load             harmonise         validate          measure          publish
 ────────         ──────           ───────────       ──────────        ─────────        ─────────
 CBS zips   →   raw.*      →     clean.buurten   →   qa.coverage_  →   qa.vintage_  →   CSV / report
 (download)     (ogr2ogr)        clean.gemeenten     results          disagreement
                                 (one schema)        (C1–C6)          (Test A/B)
```

Two ideas make the whole project make sense:

1. **A boundary dataset is not a fixed thing.** CBS republishes the Dutch neighbourhood map
   every year. Each yearly edition is a **vintage**. The 2015 map and the 2025 map are different
   datasets that describe "the same" neighbourhoods differently.

2. **The identifier is derived from the hierarchy.** A neighbourhood's code is built out of its
   municipality's code. So when municipalities merge — 484 of them in 2015, 424 in 2025 — the
   neighbourhoods inside them are silently renumbered even though no physical boundary moved.

The pipeline exists to *measure the consequence*: if you stamp every record with one vintage's
codes, how many records end up mislabelled, and by how much?

---

## 1. Coordinate reference systems — the concept everything rests on

A CRS is the answer to "what do these two numbers mean?" A point `(93000, 437000)` is
meaningless until you know the system.

There are two families:

- **Geographic** (e.g. **EPSG:4326**, WGS84): longitude/latitude in **degrees** on a sphere.
  This is GPS, this is what a `.geojson` from the web usually carries.
- **Projected** (e.g. **EPSG:28992**, "Amersfoort / RD New"): x/y in **metres** on a flat plane,
  built for one specific region — here, the Netherlands.

**Why this is the first thing, not a detail.** You cannot measure area or distance correctly in
degrees, because a degree of longitude is a different number of metres in Rotterdam than at the
equator. Every `ST_Area`, `ST_Distance`, `ST_DWithin` in this project assumes metres. All CBS
data is already EPSG:28992, so we *assert* it on load (`-a_srs EPSG:28992`) rather than trust the
file to declare it.

**The failure signature to memorise.** If a CRS is lost or assumed wrong, Dutch data lands near
coordinate `(0, 0)` — the Gulf of Guinea, off West Africa. "My data is in the ocean off Africa"
is the universal symptom of an SRID mistake. It is worth a distance sanity-check on any join.

> Interview line: *"Get the CRS wrong and every downstream number is silently wrong, not
> obviously wrong — that's what makes it dangerous."*

---

## 2. Fetch — acquisition as engineering, not a download

Script: [fetch_cbs.py](fetch_cbs.py)

Downloading a file is trivial. Downloading it *reproducibly* is the skill a data company is
paying for. Four ideas are baked in:

**Probe, don't hardcode.** CBS names files `WijkBuurtkaart_<YEAR>_v<N>.zip`, and the revision
`v<N>` is inconsistent — 2025 is `v1`, 2024 is `v2`, older years are `v3`. A hardcoded URL table
rots the moment CBS republishes a correction. The script issues a `HEAD` request for `v5` down to
`v1` and takes the first that answers `200`. It self-heals.

**Idempotency.** Re-running does no work if the files are already present and valid. A pipeline
you'll eventually run weekly in automation must be safe to run twice.

**Verify, don't assume.** After download — and on already-present files — it opens the zip and
runs an integrity check. A run interrupted mid-stream leaves a file of plausible *size* that is
actually truncated; without the check, that corruption surfaces much later and far more
confusingly, inside `ogr2ogr`.

**Atomic writes.** It streams to `file.zip.part`, then renames into place only when complete, so
an interrupted run never leaves a half-file that looks finished. (This is exactly where the
OneDrive bug bit — see §12.)

---

## 3. Load — GDAL, virtual filesystems, and `ogr2ogr`

Script: [load_to_postgis.py](load_to_postgis.py)

**GDAL** is the universal translator of geospatial data — it reads ~100 vector formats and
writes to PostGIS. `ogr2ogr` is its command-line front end, and it is the tool an employer
expects you to reach for. We shell out to it rather than loading through Python/GeoPandas because
GDAL streams straight from the file into the database without ever holding the whole 200 MB layer
in memory.

**The magic string** in the load command:

```
/vsizip//Users/.../WijkBuurtkaart_2015_v3.zip/WijkBuurtkaart_2015_v3/buurt_2015.shp
```

`/vsizip/` is a **GDAL virtual filesystem** — it reads a file *inside* a zip without unzipping it
to disk first. (`/vsicurl/` does the same for a file over HTTP; you can chain them to read a
shapefile inside a zip on a remote server, which is how the schemas were inspected before
anything was downloaded.)

**Key options and the concept behind each:**

| Option | Why |
|---|---|
| `-nlt PROMOTE_TO_MULTI` | 2015 ships `Polygon`, 2025 ships `MultiPolygon`. Forcing everything to MultiPolygon means one uniform column type across vintages. |
| `-a_srs EPSG:28992` | Assert the CRS rather than trust the file (see §1). |
| `-lco GEOMETRY_NAME=geom` | Name the geometry column consistently. |
| `-lco SPATIAL_INDEX=GIST` | Build the spatial index on load (see §6). |
| `PG_USE_COPY=YES` | Use Postgres bulk `COPY` instead of row-by-row `INSERT` — far faster. |

**The format shift is itself data.** Older vintages are shapefiles (`buurt_2015.shp`) with
uppercase fields (`BU_CODE`); newer ones are GeoPackages (`buurten` layer) with lowercase fields
(`buurtcode`). The loader *detects* which it's holding rather than assuming, because the cutover
year isn't documented and CBS may move it again.

> Aside — the shapefile is a bad format: it's really 4+ sidecar files (`.shp/.shx/.dbf/.prj`),
> caps field names at 10 characters (that's why `BU_CODE`, not `buurtcode`), and has a 2 GB
> limit. GeoPackage is a single SQLite file with none of these limits. The industry is moving off
> shapefiles; knowing *why* is a small signal of currency.

---

## 4. Harmonise — the `raw` → `clean` pattern

Script: [01_bootstrap.sql](01_bootstrap.sql)

**The three-schema convention:**

- `raw` — data exactly as it arrived, untouched. Sacred. If you need to re-derive, you start here.
- `clean` — typed, validated, harmonised, consistent across sources.
- `analysis` / `qa` — outputs and results.

This is a discipline, not decoration: you never mutate `raw`, so a mistake in `clean` is always
recoverable and every transformation is auditable.

**The core problem this file solves:** each vintage's columns are named differently. Rather than
hardcode a per-year mapping (which breaks the first time CBS renames something), the script asks
the database's own catalogue, `information_schema.columns`, which of several candidate names
actually exists, and builds the `INSERT` dynamically:

```sql
c_bcode := clean.pick_col('raw', tb, 'buurtcode', 'bu_code');  -- returns whichever exists
```

This is the exact skill a "country update" job needs: *the source moved, the meaning did not.*
You write the transformation once, against meaning, and let it adapt to naming.

**Two geometry-cleaning ideas happen here too** (detail in §5).

---

## 5. Geometry validity and the dissolve

### Validity

Real-world polygons are often **invalid**: a boundary that crosses itself (self-intersection), a
ring that isn't closed, duplicated points. Invalid geometry makes area and intersection
operations return garbage or throw.

- `ST_IsValid(geom)` → true/false
- `ST_IsValidReason(geom)` → *why*, e.g. `Self-intersection[234107 581106]`
- `ST_MakeValid(geom)` → repairs it, preserving as much as possible

On load we run `ST_MakeValid` on every polygon. This wasn't theoretical: the **2015 source
contained 7 genuinely invalid polygons** that were repaired here. One subtlety — `ST_MakeValid`
can return a `GeometryCollection` (mixing points, lines, polygons) when the input is badly broken,
so we wrap it in `ST_CollectionExtract(..., 3)` to keep only the polygonal parts.

### The dissolve, and why coastal municipalities are two rows

When building `clean.gemeenten`, we discovered CBS ships each **coastal municipality as two
polygons** sharing one code — one land, one water. So the raw layer had 484 rows for 394 actual
municipalities.

Left alone, this breaks the nesting check: joining neighbourhoods to municipalities on the code
would match each land neighbourhood against its municipality's *water* polygon and report it as
"outside its own municipality" — thousands of false failures.

The fix is a **dissolve**: `ST_Union` all parts sharing a code into one geometry.

```sql
SELECT gemeentecode, ST_Union(ST_MakeValid(geom)) ... GROUP BY gemeentecode
```

`ST_Union` is the spatial analogue of `GROUP BY ... SUM`: it merges many geometries into one. We
repair *before* unioning, because union on invalid input can fail or silently drop rings. After
this, a `UNIQUE` index enforces one row per municipality so the bug cannot silently return.

> This is the single most important habit the project teaches: **look at your data before you
> trust a join.** The count `484 ≠ 394` was the tell.

---

## 6. Spatial indexing — the concept interviewers probe

This is the highest-value idea in the whole project for a job interview.

**The problem.** "Which of 15,000 neighbourhoods contains this point?" Naively, you test the point
against all 15,000 polygons, and each exact geometric test is expensive. For 44,000 points that's
660 million exact tests. Unworkable.

**The solution: a GiST index (Generalized Search Tree).** For geometry it stores each polygon's
**bounding box** — the smallest rectangle enclosing it. A point-in-polygon query then runs in two
stages:

1. **Filter (index):** walk the tree, cheaply collect only polygons whose bounding box could
   contain the point. Reduces 15,000 candidates to a handful.
2. **Refine (exact):** run the expensive true geometric test only on that handful.

The `&&` operator in the SQL ("do these bounding boxes overlap?") is what lets the index do the
filter stage. `ST_Contains` / `ST_Intersects` then do the exact refine stage on what survives.

**How you prove it worked:** `EXPLAIN (ANALYZE, BUFFERS)` shows the query plan. Without the index
you see a `Seq Scan` (read every row); with it, an `Index Scan`. Being able to say *"I took a
spatial join from 90 seconds to under a second by adding a GiST index"* is a complete,
memorable interview answer — and it's literally what happens here.

> The two-stage filter/refine idea is general: almost every fast spatial operation is "cheap
> bounding-box filter, then expensive exact test on survivors."

---

## 7. Coverage checks — what "a valid coverage" means

Script: [02_checks_coverage.sql](02_checks_coverage.sql)

A **coverage** is a set of polygons that tiles a region *exactly*: no gaps, no overlaps, every
child nested in its parent, and the parts sum to the whole. Boundary products live or die on this
property — it's the first thing a customer notices when it breaks. The six checks each test one
way a coverage can fail:

| Check | Question | Method |
|---|---|---|
| **C1** validity | Any broken shapes? | `ST_IsValid` |
| **C2** overlaps | Do two neighbourhoods claim the same ground? | `ST_Overlaps` + area > 1 m² |
| **C3** gaps | Any ground in *no* neighbourhood? | `ST_Difference(gemeente, union of its buurten)` |
| **C4** nesting | Is each neighbourhood inside its own municipality? | `ST_Difference(buurt, its gemeente)` |
| **C5** unique codes | Does each code identify exactly one polygon? | `GROUP BY ... HAVING count > 1` |
| **C6** code structure | Do codes follow the hierarchy rule? | string logic (see §8) |

**Two conceptual traps worth internalising:**

- **`ST_Overlaps` ≠ `ST_Intersects`.** Two neighbours that merely *share a border* intersect, but
  do not overlap. Overlap means shared *interior area*. C2 uses `ST_Overlaps` precisely so that
  touching borders — which are correct — aren't reported as errors.

- **Thresholds must be explicit.** C2 ignores overlaps below 1 m² and C3 ignores gaps below
  100 m², because floating-point noise in the source produces slivers that aren't real errors.
  State the threshold in the code; never silently drop rows.

**The result design.** Every check writes a row to `qa.coverage_results` (a scorecard: check,
vintage, count, verdict) and any failing geometry to `qa.failures`. The scorecard is the "verdict
at the top" a recruiter reads; `qa.failures` is small, so it's mappable and publishable.

Result here: **18/18 PASS.** CBS data is well-built. Which raises the question in §11.

---

## 8. The code invariant — why a merger renumbers everything

This is the mechanism at the heart of the project, and C6 tests it directly.

A neighbourhood code is structured:

```
BU 0363 04 08
│  │    │  └─ buurt (2 digits)
│  │    └──── wijk / district (2 digits)
│  └───────── gemeente / municipality (4 digits)
└──────────── literal "BU"
```

A municipality code is `GM` + the *same* 4 digits. So this must always hold:

```
'GM' || substring(buurtcode from 3 for 4) = gemeentecode
```

**The consequence.** Because the neighbourhood code *contains* the municipality code, when Weesp
is absorbed into Amsterdam (GM0363), every neighbourhood in Weesp gets a new code beginning
`BU0363…`. The physical neighbourhood didn't move. Its identifier changed because its parent
changed. That is the entire reason a record labelled with one vintage's code can be "wrong" for
another vintage — and why the row counts alone (394 → 356 → 343 municipalities) already told us
the problem is large before any analysis ran.

---

## 9. The vintage tests — point-in-polygon, done twice

Script: [03_checks_vintage.sql](03_checks_vintage.sql)

Everything so far was setup. This is the measurement, and it rests on assigning each point to a
neighbourhood **under two different maps**, then comparing.

For each point we compute:

- `buurt_at_time` — the neighbourhood under the map **in force in the point's own year**
- `buurt_ref` — the neighbourhood under the **reference vintage** (2025, mimicking your NVM's
  `buurt_nr_2022` column)

That gives two genuinely different questions:

**Test A — is the stored code even correct?** Compare the *already-stored* code against the code
recomputed from the *same* vintage. Any disagreement is a plain bug (bad join, CRS error, stale
code). Expect ≈ 0%. On demo data it *is* 0% — but only because the demo stamped codes from that
same map. On real NVM, where the code was assigned by someone else long ago, Test A becomes a
real bug detector.

**Test B — does the choice of vintage matter?** Compare `buurt_at_time` against `buurt_ref`.
Disagreement here is **not a bug** — it's the measured cost of harmonising a long panel onto one
boundary set. This is the headline: **36.3%** of demo points land in a different unit depending on
the map, rising to ~44% for pre-2015 points.

A refinement worth noting: Test B also counts how many changed *municipality* (not just
neighbourhood), by comparing the 4-digit slice of the code. A municipality change is the severe
case — it breaks joins to municipal statistics, not merely neighbourhood ones.

**One honest limitation, stated in the code.** With only three vintages, a 2007 point is compared
against the 2015 map (the newest at-or-before its year that we loaded), not a true 2007 map. This
*understates* drift, making the headline a **conservative lower bound**. Saying so is the
difference between a defensible result and an overclaim.

---

## 10. The crosswalk — the deliverable a customer actually wants

Also in [03_checks_vintage.sql](03_checks_vintage.sql), written to
[results/crosswalk.csv](results/crosswalk.csv).

A QA verdict tells you *that* codes changed. A **crosswalk** tells you *how to translate* old
codes to new — which is what anyone holding old data needs when you ship a new version.

**Method: match by maximum area overlap.** For each 2015 neighbourhood, find the 2025
neighbourhood it shares the most area with. Then classify what happened using two signals:

- **fan-out** — how many new neighbourhoods does one old one touch? (many → it was **split**)
- **fan-in** — how many old ones map to the same new one? (many → they were **merged**)

Combined with "did the code change?" and "did the municipality digits change?", this yields a
change type per neighbourhood:

| change_type | count | meaning |
|---|---|---|
| unchanged | 6,987 | same code, same footprint |
| split | 3,078 | one 2015 buurt became several |
| recoded (gemeente change) | 790 | renumbered by a municipal merger |
| merged | 751 | several became one |
| recoded | 733 | code changed, footprint stable |

So **43% of 2015 neighbourhoods changed identity by 2025.** That table, framed as release notes
("v2015 → v2025: N splits, M merges…"), is the artefact that reads as a product, not homework.

---

## 11. Verification — why a passing test suite is suspicious

18/18 PASS is a *warning sign*, not a victory. A test that can never fail measures nothing. So the
harness was checked three ways — and this section is arguably the most important thing to be able
to talk about, because it's what separates a QA tool people trust from one they don't.

1. **Are the joins reaching data?** Confirmed 1,093 municipality matches and all 41,065
   neighbourhoods joined — nothing was silently skipped by a bad join key.

2. **Did the pipeline actually do work?** The 2015 source really did contain 7 invalid geometries
   that `ST_MakeValid` repaired. C1 documents real repair, not a vacuous pass.

3. **Negative control (the decisive one).** Take a real neighbourhood, shift it 300 m with
   `ST_Translate`, and re-run the logic. It reported 332,066 m² now outside its municipality and
   10 new overlaps. **The checks fire on defects that are actually there.** A check you've never
   seen fail is a check you can't trust.

The `0.00%` self-consistency result at the reference year (a point joined to its own reference map
must agree with itself) is the same idea built into the measurement: a known-correct answer that
proves the machinery before you believe the unknown ones.

> Interview framing: *"I don't trust a check until I've watched it fail on a defect I injected on
> purpose."*

---

## 12. The four bugs, as lessons

Every bug here is a transferable concept, not a typo.

**1. The OneDrive rename race.** `file.zip.part` was renamed to `file.zip` by the OS cloud-sync
agent *before* Python's own rename ran, so `os.rename` failed on a file that had downloaded
perfectly. *Lesson:* code that writes files can't assume it's the only process touching the
directory; cloud-synced folders are hostile to atomic-write patterns. *Fix:* treat "destination
already exists at the right size" as success, and keep bulk data out of synced folders entirely.

**2. `CREATE TEMP TABLE qa._gem_union`.** Postgres puts temp tables in a special `pg_temp` schema
and rejects a schema qualifier on them. *Lesson:* temp tables have their own namespace rules.
*Fix:* a regular table — which is better here anyway, since you want to inspect the dissolved
geometry when a gap appears.

**3. Duplicate municipality rows (§5).** The `484 ≠ 394` count mismatch. *Lesson:* the highest-
value habit in spatial work is looking at cardinalities before trusting a join. *Fix:* dissolve,
then a UNIQUE index so it can't recur.

**4. `row_number()` colliding on point IDs.** Every point sampled from one polygon got the same
id, so the primary key rejected the insert. The cause is subtle and worth understanding: a
**set-returning function** like `ST_Dump` in the SELECT list expands one input row into many
output rows, but **window functions (`row_number()`) are evaluated *before* that expansion** — so
the numbering was assigned per-polygon, not per-point. *Lesson:* know your query's evaluation
order. *Fix:* generate the points in a `LATERAL` join first, *then* number the expanded rows.

---

## 13. The 60-second interview version

If someone says "tell me about a project," this is the spine:

> I built a PostGIS pipeline that checks whether point data is assigned to the correct *vintage*
> of administrative boundary. Dutch neighbourhood boundaries are re-cut annually, and because the
> neighbourhood code is derived from the municipality code, every municipal merger silently
> renumbers the neighbourhoods inside it. I loaded three vintages with `ogr2ogr`, harmonised the
> differing schemas by resolving column names dynamically against `information_schema`, repaired
> invalid geometry with `ST_MakeValid`, and dissolved a duplicate-row artefact I found by
> checking cardinalities. Then I ran a six-check topological validation — gaps, overlaps, nesting,
> uniqueness, code structure — and a point-in-polygon comparison across vintages that showed
> ~36% of points change neighbourhood depending on which year's map you use. I validated the whole
> harness with negative controls, injecting a shifted polygon to confirm the checks actually fire.
> The output is a scorecard plus an old-to-new crosswalk — the artefact a data customer needs when
> you ship a new version.

Every clause in that paragraph is a concept from the sections above. If you can expand any one of
them on demand, you understand the project.
