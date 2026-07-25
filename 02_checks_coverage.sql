-- ===========================================================================
--  NL BOUNDARY VINTAGE QA -- FILE 02.  Is each vintage a valid coverage?
--
--  A "coverage" is a set of polygons that tiles a region exactly: no gaps, no
--  overlaps, every child nested in its parent. Boundary products live or die on
--  this property, and it is the thing customers notice first when it breaks.
--
--  Six checks, all writing into qa.coverage_results. Failure geometry goes into
--  qa.failures, which stays small enough to publish and map.
--
--  Run after 01_bootstrap.sql. Takes a few minutes on three vintages.
-- ===========================================================================

SET search_path TO clean, qa, public;

DROP TABLE IF EXISTS qa.coverage_results;
CREATE TABLE qa.coverage_results (
    check_id    text,
    check_name  text,
    vintage     int,
    n_failures  bigint,
    metric      numeric,      -- optional magnitude, e.g. total gap area in m²
    metric_unit text,
    verdict     text          -- PASS / WARN / FAIL
);

DROP TABLE IF EXISTS qa.failures;
CREATE TABLE qa.failures (
    check_id   text,
    vintage    int,
    ref_a      text,
    ref_b      text,
    note       text,
    metric     numeric,
    geom       geometry(Geometry, 28992)
);


-- ###########################################################################
-- C1.  Geometry validity.
-- ###########################################################################
-- 01_bootstrap already ran ST_MakeValid, so a non-zero count here means input
-- so badly broken that repair could not save it. That is worth knowing rather
-- than hiding.

INSERT INTO qa.failures (check_id, vintage, ref_a, note, geom)
SELECT 'C1', vintage, buurtcode,
       split_part(ST_IsValidReason(geom), '[', 1),
       ST_PointOnSurface(geom)
FROM clean.buurten
WHERE NOT ST_IsValid(geom);

INSERT INTO qa.coverage_results
SELECT 'C1', 'Geometry validity', v.vintage,
       count(f.*), NULL, NULL,
       CASE WHEN count(f.*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (SELECT DISTINCT vintage FROM clean.buurten) v
LEFT JOIN qa.failures f ON f.check_id = 'C1' AND f.vintage = v.vintage
GROUP BY v.vintage;


-- ###########################################################################
-- C2.  Overlaps between neighbouring buurten.
-- ###########################################################################
-- Two polygons that merely share an edge do NOT satisfy ST_Overlaps, so a hit
-- here is a real double-counted area, not a touching border. The `&&` bounding
-- box test in the join lets the GiST index do the filtering first.
--
-- 1 m² threshold: below that it is floating-point noise from the source, not a
-- modelling error. State the threshold rather than quietly dropping rows.

INSERT INTO qa.failures (check_id, vintage, ref_a, ref_b, note, metric, geom)
SELECT 'C2', a.vintage, a.buurtcode, b.buurtcode,
       'overlapping area',
       round(ST_Area(ST_Intersection(a.geom, b.geom))::numeric, 1),
       ST_PointOnSurface(ST_Intersection(a.geom, b.geom))
FROM clean.buurten a
JOIN clean.buurten b
  ON a.vintage = b.vintage
 AND a.buurtcode < b.buurtcode        -- each pair once
 AND a.geom && b.geom
WHERE ST_Overlaps(a.geom, b.geom)
  AND ST_Area(ST_Intersection(a.geom, b.geom)) > 1.0;

INSERT INTO qa.coverage_results
SELECT 'C2', 'Overlapping buurten', v.vintage,
       count(f.*), round(COALESCE(sum(f.metric), 0), 1), 'm²',
       CASE WHEN count(f.*) = 0 THEN 'PASS'
            WHEN COALESCE(sum(f.metric), 0) < 1000 THEN 'WARN'
            ELSE 'FAIL' END
FROM (SELECT DISTINCT vintage FROM clean.buurten) v
LEFT JOIN qa.failures f ON f.check_id = 'C2' AND f.vintage = v.vintage
GROUP BY v.vintage;


-- ###########################################################################
-- C3.  Gaps: do the buurten fill their gemeente exactly?
-- ###########################################################################
-- Union every buurt in a gemeente and compare the result to the gemeente
-- polygon. A positive difference is territory belonging to no buurt.
--
-- MODELLING NOTE: water buurten are included deliberately. CBS gemeente
-- polygons include inland water, so excluding water buurten here would
-- manufacture gaps that do not exist. If you change this, change it knowingly.

-- A real table, not TEMP: PostgreSQL puts temp tables in pg_temp and rejects a schema
-- qualifier on them. Keeping it persistent is better here anyway -- when a gap shows up you
-- will want to look at the dissolved geometry that produced it.
DROP TABLE IF EXISTS qa._gem_union;
CREATE TABLE qa._gem_union AS
SELECT vintage, gemeentecode, ST_Union(geom) AS g
FROM clean.buurten
GROUP BY vintage, gemeentecode;

CREATE INDEX ON qa._gem_union USING GIST (g);

INSERT INTO qa.failures (check_id, vintage, ref_a, note, metric, geom)
SELECT 'C3', g.vintage, g.gemeentecode,
       'territory in no buurt',
       round(ST_Area(d.diff)::numeric, 1),
       ST_PointOnSurface(d.diff)
FROM clean.gemeenten g
JOIN qa._gem_union u
  ON u.vintage = g.vintage AND u.gemeentecode = g.gemeentecode
CROSS JOIN LATERAL (SELECT ST_Difference(g.geom, u.g) AS diff) d
WHERE NOT ST_IsEmpty(d.diff)
  AND ST_Area(d.diff) > 100.0;        -- 100 m²: below this is edge noise

INSERT INTO qa.coverage_results
SELECT 'C3', 'Gaps within gemeente', v.vintage,
       count(f.*), round(COALESCE(sum(f.metric), 0), 1), 'm²',
       CASE WHEN count(f.*) = 0 THEN 'PASS'
            WHEN COALESCE(sum(f.metric), 0) < 10000 THEN 'WARN'
            ELSE 'FAIL' END
FROM (SELECT DISTINCT vintage FROM clean.buurten) v
LEFT JOIN qa.failures f ON f.check_id = 'C3' AND f.vintage = v.vintage
GROUP BY v.vintage;


-- ###########################################################################
-- C4.  Nesting: is each buurt geometrically inside its own gemeente?
-- ###########################################################################

INSERT INTO qa.failures (check_id, vintage, ref_a, ref_b, note, metric, geom)
SELECT 'C4', b.vintage, b.buurtcode, b.gemeentecode,
       'buurt area outside its gemeente',
       round(ST_Area(d.diff)::numeric, 1),
       ST_PointOnSurface(d.diff)
FROM clean.buurten b
JOIN clean.gemeenten g
  ON g.vintage = b.vintage AND g.gemeentecode = b.gemeentecode
CROSS JOIN LATERAL (SELECT ST_Difference(b.geom, g.geom) AS diff) d
WHERE NOT ST_IsEmpty(d.diff)
  AND ST_Area(d.diff) > 100.0;

INSERT INTO qa.coverage_results
SELECT 'C4', 'Buurt nested in gemeente', v.vintage,
       count(f.*), round(COALESCE(sum(f.metric), 0), 1), 'm²',
       CASE WHEN count(f.*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (SELECT DISTINCT vintage FROM clean.buurten) v
LEFT JOIN qa.failures f ON f.check_id = 'C4' AND f.vintage = v.vintage
GROUP BY v.vintage;


-- ###########################################################################
-- C5.  Duplicate buurt codes within a vintage.
-- ###########################################################################
-- A code must identify exactly one polygon inside one vintage. If it does not,
-- every downstream join silently fans out.

INSERT INTO qa.failures (check_id, vintage, ref_a, note, metric, geom)
SELECT 'C5', vintage, buurtcode, 'duplicate code', count(*), NULL
FROM clean.buurten
GROUP BY vintage, buurtcode
HAVING count(*) > 1;

INSERT INTO qa.coverage_results
SELECT 'C5', 'Unique buurt codes', v.vintage,
       count(f.*), NULL, NULL,
       CASE WHEN count(f.*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (SELECT DISTINCT vintage FROM clean.buurten) v
LEFT JOIN qa.failures f ON f.check_id = 'C5' AND f.vintage = v.vintage
GROUP BY v.vintage;


-- ###########################################################################
-- C6.  The code-structure invariant.
-- ###########################################################################
-- buurtcode = 'BU' + gemeente(4) + wijk(2) + buurt(2)
-- gemeentecode = 'GM' + the same 4 digits
--
-- This is WHY a municipal merger renumbers every buurt inside it, and it is the
-- root cause of the vintage problem that file 03 measures.

INSERT INTO qa.failures (check_id, vintage, ref_a, ref_b, note, geom)
SELECT 'C6', vintage, buurtcode, gemeentecode,
       'code prefix does not match gemeentecode', NULL
FROM clean.buurten
WHERE buurtcode IS NOT NULL
  AND gemeentecode IS NOT NULL
  AND (length(buurtcode) <> 10
       OR 'GM' || substring(buurtcode from 3 for 4) <> gemeentecode);

INSERT INTO qa.coverage_results
SELECT 'C6', 'Code structure invariant', v.vintage,
       count(f.*), NULL, NULL,
       CASE WHEN count(f.*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (SELECT DISTINCT vintage FROM clean.buurten) v
LEFT JOIN qa.failures f ON f.check_id = 'C6' AND f.vintage = v.vintage
GROUP BY v.vintage;


-- ###########################################################################
-- The scorecard.
-- ###########################################################################

CREATE INDEX IF NOT EXISTS idx_qa_failures_geom ON qa.failures USING GIST (geom);
ANALYZE qa.failures;

SELECT vintage,
       count(*)                                     AS checks_run,
       count(*) FILTER (WHERE verdict = 'PASS')     AS passed,
       count(*) FILTER (WHERE verdict = 'WARN')     AS warned,
       count(*) FILTER (WHERE verdict = 'FAIL')     AS failed
FROM qa.coverage_results
GROUP BY vintage
ORDER BY vintage;

SELECT * FROM qa.coverage_results ORDER BY vintage, check_id;
