-- File 03 — are points assigned to the right vintage? Two separate questions:
--
-- Test A — is the stored assignment even correct?
--     Re-run the point-in-polygon join against the same vintage the stored code claims to come
--     from, and compare. Any disagreement is a plain bug — a bad join, a CRS slip, a stale code.
--     Expect ~0%.
--
-- Test B — does the choice of vintage matter?
--     Join each point to the vintage in force in its own year, and compare that to the stored
--     reference-vintage code. Disagreement here isn't a bug; it's the measured cost of squashing
--     a long panel onto a single boundary set.
--
-- Test B is the headline. Plot its rate against observation year and you get a curve that's flat
-- near the reference year and climbs as you go back, stepping at the municipal-merger years.
--
-- Run after 01 and 02.

SET search_path TO clean, qa, public;


-- Part 1.  Which vintage was in force in a given year?
-- With only three vintages loaded I can't know the exact boundary set for every year, so I use
-- the newest loaded vintage at or before the observation year. That understates drift (a 2007
-- point gets 2015 boundaries if 2015 is the oldest you loaded), which makes the headline
-- conservative — a bound I can defend beats a precise number I can't.

CREATE OR REPLACE FUNCTION clean.vintage_for_year(p_year int)
RETURNS int LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT max(vintage) FROM clean.buurten WHERE vintage <= p_year),
        (SELECT min(vintage) FROM clean.buurten)
    );
$$;

-- The reference vintage: the one the stored codes were built against.
-- For your NVM extract this is 2022 (buurt_nr_2022). Change it here if not.
CREATE OR REPLACE FUNCTION clean.reference_vintage()
RETURNS int LANGUAGE sql STABLE AS $$
    SELECT max(vintage) FROM clean.buurten;
$$;


-- Part 2.  Assign every point twice.

DROP TABLE IF EXISTS qa.point_assignment;
CREATE TABLE qa.point_assignment AS
WITH ref AS (SELECT clean.reference_vintage() AS v)
SELECT
    p.point_id,
    p.obs_year,
    p.buurt_stored,
    clean.vintage_for_year(p.obs_year)          AS vintage_at_time,
    (SELECT v FROM ref)                         AS vintage_ref,
    -- assignment under the boundaries in force at the time
    (SELECT b.buurtcode FROM clean.buurten b
      WHERE b.vintage = clean.vintage_for_year(p.obs_year)
        AND ST_Contains(b.geom, p.geom)
      LIMIT 1)                                  AS buurt_at_time,
    -- assignment under the reference vintage
    (SELECT b.buurtcode FROM clean.buurten b
      WHERE b.vintage = (SELECT v FROM ref)
        AND ST_Contains(b.geom, p.geom)
      LIMIT 1)                                  AS buurt_ref
FROM clean.points p;

ALTER TABLE qa.point_assignment ADD PRIMARY KEY (point_id);
CREATE INDEX ON qa.point_assignment (obs_year);
ANALYZE qa.point_assignment;


-- Part 3.  Coverage of the point layer itself.
-- Before comparing assignments, confirm every point landed somewhere. Points in
-- no polygon are usually a CRS problem, a bad geocode, or a coastal boundary.

INSERT INTO qa.coverage_results
SELECT 'P1', 'Points assigned under reference vintage',
       clean.reference_vintage(),
       count(*) FILTER (WHERE buurt_ref IS NULL),
       round(100.0 * count(*) FILTER (WHERE buurt_ref IS NULL) / NULLIF(count(*), 0), 3),
       '% unassigned',
       CASE WHEN count(*) FILTER (WHERE buurt_ref IS NULL) = 0 THEN 'PASS'
            WHEN count(*) FILTER (WHERE buurt_ref IS NULL)
                 < 0.001 * count(*) THEN 'WARN'
            ELSE 'FAIL' END
FROM qa.point_assignment;

-- Points falling inside more than one buurt of the same vintage: only possible
-- if the coverage overlaps, so this should mirror check C2.
INSERT INTO qa.coverage_results
SELECT 'P2', 'Points in exactly one buurt', clean.reference_vintage(),
       count(*), NULL, NULL,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (
    SELECT p.point_id
    FROM clean.points p
    JOIN clean.buurten b
      ON b.vintage = clean.reference_vintage()
     AND ST_Contains(b.geom, p.geom)
    GROUP BY p.point_id
    HAVING count(*) > 1
) x;


-- Part 4.  Test A -- is the stored code correct for its own vintage?

DROP TABLE IF EXISTS qa.test_a;
CREATE TABLE qa.test_a AS
SELECT
    obs_year,
    count(*)                                                      AS n_points,
    count(*) FILTER (WHERE buurt_stored IS DISTINCT FROM buurt_ref) AS n_mismatch,
    round(100.0 * count(*) FILTER (WHERE buurt_stored IS DISTINCT FROM buurt_ref)
          / NULLIF(count(*), 0), 3)                               AS pct_mismatch
FROM qa.point_assignment
WHERE buurt_stored IS NOT NULL
GROUP BY obs_year
ORDER BY obs_year;

INSERT INTO qa.coverage_results
SELECT 'A', 'Stored code matches recomputed (same vintage)',
       clean.reference_vintage(),
       COALESCE(sum(n_mismatch), 0),
       round(100.0 * COALESCE(sum(n_mismatch), 0)
             / NULLIF(sum(n_points), 0), 3),
       '% mismatched',
       CASE WHEN COALESCE(sum(n_mismatch), 0) = 0 THEN 'PASS'
            WHEN sum(n_mismatch) < 0.001 * sum(n_points) THEN 'WARN'
            ELSE 'FAIL' END
FROM qa.test_a;


-- Part 5.  Test B -- does the vintage choice change the answer? (the headline result)

DROP TABLE IF EXISTS qa.vintage_disagreement;
CREATE TABLE qa.vintage_disagreement AS
SELECT
    obs_year,
    vintage_at_time,
    vintage_ref,
    count(*)                                                          AS n_points,
    count(*) FILTER (WHERE buurt_at_time IS DISTINCT FROM buurt_ref)  AS n_changed,
    round(100.0 * count(*) FILTER (WHERE buurt_at_time IS DISTINCT FROM buurt_ref)
          / NULLIF(count(*), 0), 2)                                   AS pct_changed,
    -- Of those that changed, how many changed municipality, not just buurt? A gemeente change
    -- is the worse case: it breaks joins to municipal statistics, not just neighbourhood ones.
    count(*) FILTER (
        WHERE substring(buurt_at_time from 3 for 4)
              IS DISTINCT FROM substring(buurt_ref from 3 for 4)
    )                                                                 AS n_gemeente_changed
FROM qa.point_assignment
WHERE buurt_at_time IS NOT NULL AND buurt_ref IS NOT NULL
GROUP BY obs_year, vintage_at_time, vintage_ref
ORDER BY obs_year;

INSERT INTO qa.coverage_results
SELECT 'B', 'Assignment stable across vintages', clean.reference_vintage(),
       COALESCE(sum(n_changed), 0),
       round(100.0 * COALESCE(sum(n_changed), 0)
             / NULLIF(sum(n_points), 0), 2),
       '% changed unit',
       'INFO'          -- not pass/fail: this is a measurement, not a bug
FROM qa.vintage_disagreement;


-- Part 6.  The crosswalk: old code -> new code.
-- For every buurt in the oldest loaded vintage, find the reference-vintage buurt
-- it overlaps most, and classify what happened to it. This is the artefact a
-- data customer actually needs when you ship a new version.

DROP TABLE IF EXISTS qa.crosswalk;
CREATE TABLE qa.crosswalk AS
WITH old AS (
    SELECT * FROM clean.buurten WHERE vintage = (SELECT min(vintage) FROM clean.buurten)
),
new AS (
    SELECT * FROM clean.buurten WHERE vintage = clean.reference_vintage()
),
pairs AS (
    SELECT
        o.buurtcode                          AS old_code,
        o.buurtnaam                          AS old_naam,
        n.buurtcode                          AS new_code,
        n.buurtnaam                          AS new_naam,
        ST_Area(ST_Intersection(o.geom, n.geom))       AS shared_area,
        ST_Area(o.geom)                                AS old_area,
        row_number() OVER (PARTITION BY o.buurtcode
                           ORDER BY ST_Area(ST_Intersection(o.geom, n.geom)) DESC) AS rk
    FROM old o
    JOIN new n ON o.geom && n.geom AND ST_Intersects(o.geom, n.geom)
    WHERE ST_Area(ST_Intersection(o.geom, n.geom)) > 1.0
),
best AS (
    SELECT *, round((100.0 * shared_area / NULLIF(old_area, 0))::numeric, 1) AS pct_retained
    FROM pairs WHERE rk = 1
),
fanin AS (
    SELECT new_code, count(*) AS n_old_mapping_here
    FROM best GROUP BY new_code
),
fanout AS (
    SELECT old_code, count(*) AS n_new_touched
    FROM pairs GROUP BY old_code
)
SELECT
    b.old_code, b.old_naam, b.new_code, b.new_naam, b.pct_retained,
    fo.n_new_touched,
    fi.n_old_mapping_here,
    CASE
        WHEN b.old_code = b.new_code AND b.pct_retained > 99 THEN 'unchanged'
        WHEN b.old_code <> b.new_code AND b.pct_retained > 99
             AND substring(b.old_code from 3 for 4)
                 <> substring(b.new_code from 3 for 4)      THEN 'recoded (gemeente change)'
        WHEN b.old_code <> b.new_code AND b.pct_retained > 99 THEN 'recoded'
        WHEN fi.n_old_mapping_here > 1                       THEN 'merged'
        WHEN fo.n_new_touched > 1 AND b.pct_retained <= 99    THEN 'split'
        ELSE 'boundary shift'
    END AS change_type
FROM best b
LEFT JOIN fanin  fi ON fi.new_code = b.new_code
LEFT JOIN fanout fo ON fo.old_code = b.old_code;

CREATE INDEX ON qa.crosswalk (old_code);
ANALYZE qa.crosswalk;


-- Report.

-- Headline: the curve.
SELECT obs_year, vintage_at_time, n_points, n_changed, pct_changed, n_gemeente_changed
FROM qa.vintage_disagreement
ORDER BY obs_year;

-- Change composition, the release-notes summary.
SELECT change_type, count(*) AS n
FROM qa.crosswalk
GROUP BY change_type
ORDER BY n DESC;

-- Full scorecard including the point checks.
SELECT * FROM qa.coverage_results ORDER BY vintage, check_id;
