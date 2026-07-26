-- File 01 — schemas, and folding every vintage into one clean shape.
-- Run this after load_to_postgis.py has created the raw.buurten_<YEAR> tables.
--
-- The awkward bit: each vintage names its columns differently. 2015 (shapefile) has
-- bu_code / gm_code / aant_inw; 2025 (GeoPackage) has buurtcode / gemeentecode /
-- aantal_inwoners. Rather than a hardcoded per-year mapping that breaks the moment CBS
-- renames something, I look up which of a few candidate names actually exists and build the
-- INSERT on the fly. Same problem a boundaries team hits on every country update: the source
-- moved, the meaning didn't.

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS clean;
CREATE SCHEMA IF NOT EXISTS analysis;
CREATE SCHEMA IF NOT EXISTS qa;

SET search_path TO clean, raw, qa, public;


-- Part 1.  Target tables.

-- Deliberately no primary key on (vintage, buurtcode). Duplicate codes are one of the things
-- check C5 hunts for, and a constraint here would abort the load instead of letting me measure
-- the problem.

DROP TABLE IF EXISTS clean.buurten CASCADE;
CREATE TABLE clean.buurten (
    vintage        int          NOT NULL,
    buurtcode      text,
    buurtnaam      text,
    wijkcode       text,
    gemeentecode   text,
    gemeentenaam   text,
    is_water       boolean,
    ind_wijziging  int,          -- CBS's own boundary-change flag
    inwoners       int,
    geom           geometry(MultiPolygon, 28992)
);

-- One row per gemeente per vintage, land and water dissolved together.
--
-- Why dissolve: CBS ships coastal municipalities as two rows — one land polygon, one water
-- polygon — sharing a gemeentecode (484 rows for 394 municipalities in 2015). Join buurten to
-- that on gemeentecode and it fans out: every land buurt gets compared against its
-- municipality's water polygon and flagged as lying outside its own gemeente. Dissolving first
-- gives the true municipal extent, which is what checks C3 and C4 actually mean to test.
DROP TABLE IF EXISTS clean.gemeenten CASCADE;
CREATE TABLE clean.gemeenten (
    vintage        int          NOT NULL,
    gemeentecode   text,
    gemeentenaam   text,
    has_water_part boolean,     -- true if CBS supplied a separate water polygon
    geom           geometry(MultiPolygon, 28992)
);

-- The point-layer contract. Filled either from BAG (publishable) or from NVM
-- (private, never published with geometry). Downstream SQL does not care which.
CREATE TABLE IF NOT EXISTS clean.points (
    point_id      bigint PRIMARY KEY,
    obs_year      int    NOT NULL,      -- year the observation refers to
    geom          geometry(Point, 28992) NOT NULL,
    buurt_stored  text                  -- the code already on the record, if any
);


-- Part 2.  Column-name resolution.

-- Returns the first candidate column that actually exists on the table, or NULL.
CREATE OR REPLACE FUNCTION clean.pick_col(
    p_schema text, p_table text, VARIADIC p_candidates text[]
) RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE c text;
BEGIN
    FOREACH c IN ARRAY p_candidates LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = p_schema
              AND table_name   = p_table
              AND column_name  = c
        ) THEN
            RETURN c;
        END IF;
    END LOOP;
    RETURN NULL;
END $$;

-- Small helper: emit `colname` or the literal NULL cast, so a missing optional
-- column does not break the generated statement.
CREATE OR REPLACE FUNCTION clean.col_or_null(p_col text, p_type text)
RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT CASE WHEN p_col IS NULL THEN 'NULL::' || p_type
                ELSE quote_ident(p_col) || '::' || p_type END $$;


-- Part 3.  Harmonise one vintage.

CREATE OR REPLACE FUNCTION clean.harmonise_vintage(p_year int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    tb        text := format('buurten_%s',   p_year);
    tg        text := format('gemeenten_%s', p_year);
    c_bcode   text; c_bnaam text; c_wcode text; c_gcode text; c_gnaam text;
    c_water   text; c_ind   text; c_inw   text;
    g_gcode   text; g_gnaam text; g_water text;
    n_b       bigint; n_g bigint;
BEGIN
    IF to_regclass('raw.' || tb) IS NULL THEN
        RAISE EXCEPTION 'raw.% does not exist -- run load_to_postgis.py first', tb;
    END IF;

    -- Buurt level. Candidates are listed newest-name-first, then legacy.
    c_bcode := clean.pick_col('raw', tb, 'buurtcode', 'bu_code');
    c_bnaam := clean.pick_col('raw', tb, 'buurtnaam', 'bu_naam');
    c_wcode := clean.pick_col('raw', tb, 'wijkcode',  'wk_code');
    c_gcode := clean.pick_col('raw', tb, 'gemeentecode', 'gm_code');
    c_gnaam := clean.pick_col('raw', tb, 'gemeentenaam', 'gm_naam');
    c_water := clean.pick_col('raw', tb, 'water');
    c_ind   := clean.pick_col('raw', tb, 'indelingswijziging_wijken_en_buurten', 'ind_wbi');
    c_inw   := clean.pick_col('raw', tb, 'aantal_inwoners', 'aant_inw');

    IF c_bcode IS NULL THEN
        RAISE EXCEPTION 'raw.%: no buurt code column found (looked for buurtcode, bu_code)', tb;
    END IF;

    DELETE FROM clean.buurten WHERE vintage = p_year;

    EXECUTE format($f$
        INSERT INTO clean.buurten
            (vintage, buurtcode, buurtnaam, wijkcode, gemeentecode, gemeentenaam,
             is_water, ind_wijziging, inwoners, geom)
        SELECT
            %1$s,
            btrim(%2$s), %3$s, %4$s, btrim(%5$s), %6$s,
            CASE WHEN upper(btrim(%7$s)) IN ('JA','J','1','TRUE') THEN true
                 WHEN %7$s IS NULL THEN NULL ELSE false END,
            %8$s, %9$s,
            -- MakeValid can return a GeometryCollection on badly broken input;
            -- CollectionExtract(...,3) keeps only the polygonal parts.
            ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
                ::geometry(MultiPolygon, 28992)
        FROM raw.%10$I
        WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
    $f$,
        p_year,
        clean.col_or_null(c_bcode, 'text'),
        clean.col_or_null(c_bnaam, 'text'),
        clean.col_or_null(c_wcode, 'text'),
        clean.col_or_null(c_gcode, 'text'),
        clean.col_or_null(c_gnaam, 'text'),
        COALESCE(quote_ident(c_water), 'NULL'),
        clean.col_or_null(c_ind, 'int'),
        clean.col_or_null(c_inw, 'int'),
        tb
    );
    GET DIAGNOSTICS n_b = ROW_COUNT;

    -- Gemeente level, same pattern.
    n_g := 0;
    IF to_regclass('raw.' || tg) IS NOT NULL THEN
        g_gcode := clean.pick_col('raw', tg, 'gemeentecode', 'gm_code');
        g_gnaam := clean.pick_col('raw', tg, 'gemeentenaam', 'gm_naam');
        g_water := clean.pick_col('raw', tg, 'water');

        DELETE FROM clean.gemeenten WHERE vintage = p_year;

        EXECUTE format($f$
            INSERT INTO clean.gemeenten
                (vintage, gemeentecode, gemeentenaam, has_water_part, geom)
            SELECT
                %1$s,
                btrim(%2$s),
                min(%3$s),
                bool_or(CASE WHEN upper(btrim(%4$s)) IN ('JA','J','1','TRUE')
                             THEN true ELSE false END),
                -- Repair each part before unioning: ST_Union on invalid input can fail
                -- outright or silently drop rings.
                ST_Multi(ST_CollectionExtract(ST_Union(ST_MakeValid(geom)), 3))
                    ::geometry(MultiPolygon, 28992)
            FROM raw.%5$I
            WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
            GROUP BY btrim(%2$s)
        $f$,
            p_year,
            clean.col_or_null(g_gcode, 'text'),
            clean.col_or_null(g_gnaam, 'text'),
            COALESCE(quote_ident(g_water), 'NULL'),
            tg
        );
        GET DIAGNOSTICS n_g = ROW_COUNT;
    END IF;

    RETURN format('vintage %s: %s buurten, %s gemeenten  [code col: %s]',
                  p_year, n_b, n_g, c_bcode);
END $$;


-- Part 4.  Run it, then index.

-- Harmonise every vintage that was loaded, whatever years those happen to be.
DO $$
DECLARE y int; msg text;
BEGIN
    FOR y IN
        SELECT DISTINCT substring(table_name from 'buurten_(\d{4})')::int
        FROM information_schema.tables
        WHERE table_schema = 'raw' AND table_name ~ '^buurten_\d{4}$'
        ORDER BY 1
    LOOP
        SELECT clean.harmonise_vintage(y) INTO msg;
        RAISE NOTICE '%', msg;
    END LOOP;
END $$;

CREATE INDEX IF NOT EXISTS idx_buurten_geom    ON clean.buurten   USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_gemeenten_geom  ON clean.gemeenten USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_buurten_vintage ON clean.buurten   (vintage, buurtcode);
-- Unique, not merely indexed: after the dissolve above, a duplicate here would mean the
-- grouping failed, and every downstream area comparison would be silently doubled.
CREATE UNIQUE INDEX IF NOT EXISTS idx_gemeenten_vint
    ON clean.gemeenten (vintage, gemeentecode);

ANALYZE clean.buurten;
ANALYZE clean.gemeenten;

-- Sanity summary. Expect the buurt count to grow across vintages.
SELECT vintage,
       count(*)                             AS buurten,
       count(*) FILTER (WHERE is_water)     AS water_buurten,
       count(DISTINCT gemeentecode)         AS gemeenten
FROM clean.buurten
GROUP BY vintage
ORDER BY vintage;
