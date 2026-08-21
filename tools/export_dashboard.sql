-- =============================================================================
-- export_dashboard.sql — build the SPA prototype's data payload
--
-- Emits a single JSON document read by dashboard/index.html. Everything the
-- dashboard shows comes from the reporting views, not from bespoke queries, so
-- the prototype and any real BI tool would read identical numbers.
--
--   psql ... -tAqX -f tools/export_dashboard.sql > dashboard/data.json
-- =============================================================================

set search_path = kpi, public;

with

years as (
    select id, code, fiscal_year
      from kpi.reporting_period
     where period_type = 'year' and fiscal_year between 2023 and 2025
),

-- Institutional scorecard: one row per KPI per year.
scorecard as (
    select
        rp.fiscal_year,
        cat.code                                as category_code,
        cat.name                                as category_name,
        cat.sort_order                          as category_order,
        idef.code                               as kpi_code,
        idef.name                               as kpi_name,
        idef.unit,
        idef.value_type::text                   as value_type,
        idef.aggregation_method::text           as aggregation_method,
        idef.is_indexed,
        idef.definition_status::text            as definition_status,
        round(h.value, idef.decimal_places)     as value,
        round(h.target_value, 2)                as target_value,
        round(h.achievement_pct, 1)             as achievement_pct,
        h.performance_band
    from kpi.v_institution_kpi_headline h
    join years rp                       on rp.id = h.reporting_period_id
    join kpi.indicator_definition idef  on idef.id = h.indicator_definition_id
    left join kpi.kpi_category cat      on cat.id = idef.kpi_category_id
    where idef.parent_indicator_id is null
),

-- Category performance, for the executive tiles.
categories as (
    select
        rp.fiscal_year,
        c.category_code,
        c.category_name,
        c.sort_order,
        c.kpi_count,
        c.on_track_count,
        c.at_risk_count,
        c.off_track_count,
        c.no_target_count,
        round(c.avg_achievement_pct, 1) as avg_achievement_pct
    from kpi.v_institution_category_performance c
    join years rp on rp.id = c.reporting_period_id
),

-- Program comparison for one KPI at a time.
programs as (
    select
        rp.fiscal_year,
        prg.code                            as program_code,
        prg.name                            as program_name,
        idef.code                           as kpi_code,
        round(h.value, idef.decimal_places) as value,
        round(h.target_value, 2)            as target_value,
        round(h.achievement_pct, 1)         as achievement_pct,
        h.performance_band
    from kpi.v_program_kpi_headline h
    join years rp                      on rp.id = h.reporting_period_id
    join kpi.program prg               on prg.id = h.program_id
    join kpi.indicator_definition idef on idef.id = h.indicator_definition_id
    where idef.parent_indicator_id is null
),

-- Sex disaggregation: the "a" sub-indicators, derived from their parent.
female_share as (
    select
        rp.fiscal_year,
        f.parent_kpi_code,
        f.share_kpi_code,
        f.female_count,
        f.total_count,
        f.female_share_pct
    from kpi.v_institution_female_share f
    join years rp on rp.id = f.reporting_period_id
),

-- Geography, from the observation-grain fact view.
geography as (
    select
        f.fiscal_year,
        c.iso3166_alpha3 as country_code,
        c.name           as country_name,
        c.region,
        count(*)                  as observation_count,
        count(distinct f.project_id) as project_count
    -- Fact rows sit at the observation's own period (a quarter), so this
    -- filters on the fiscal year the view already carries rather than joining
    -- to the annual period ids.
    from kpi.v_kpi_fact f
    join kpi.country c on c.id = f.country_id
    where f.fiscal_year between 2023 and 2025
    group by f.fiscal_year, c.iso3166_alpha3, c.name, c.region
),

-- Data quality across the seven dimensions.
dq_dimensions as (
    select dimension, total_flags, open_flags, under_review_flags,
           resolved_flags, blocking_flags
    from kpi.v_dq_dimension_summary
),

dq_flags as (
    select dimension, rule_name, severity, status::text as status,
           blocks_publication, detail, program_name, project_name,
           indicator_code, reporting_period_code, entity_name
    from kpi.v_dq_flag_detail
    order by blocks_publication desc, dimension, dq_flag_id
    limit 60
),

ingestion as (
    select source_system, integration_mode,
           to_char(started_at, 'YYYY-MM-DD') as started_on,
           status, staged_records, transformed, flagged, rejected,
           acceptance_rate_pct
    from kpi.v_ingestion_summary
),

-- Lineage: one institutional KPI traced to source records.
lineage as (
    select program_name, project_name, activity_name, indicator_code,
           disaggregation_key, numerator, denominator, status::text as status,
           evidence_uri is not null as has_evidence
    from kpi.v_kpi_lineage
    where indicator_code = 'KPI_6'
    limit 40
),

-- Deduplication effect: institutional distinct count vs the naive sum.
dedup as (
    select
        rp.fiscal_year,
        idef.code as kpi_code,
        idef.name as kpi_name,
        (select round(h.value, 0) from kpi.v_institution_kpi_headline h
          where h.indicator_definition_id = idef.id
            and h.reporting_period_id = rp.id)               as deduplicated,
        (select round(sum(p.value), 0) from kpi.v_program_kpi_headline p
          where p.indicator_definition_id = idef.id
            and p.reporting_period_id = rp.id)               as naive_sum
    from kpi.indicator_definition idef
    cross join years rp
    where idef.aggregation_method = 'distinct_count'
),

counts as (
    select
        (select count(*) from kpi.program)                        as programs,
        (select count(*) from kpi.project)                        as projects,
        (select count(*) from kpi.activity)                       as activities,
        (select count(*) from kpi.observation)                    as observations,
        (select count(*) from kpi.entity where merged_into_id is null) as entities,
        (select count(*) from kpi.indicator_definition)           as indicators,
        (select count(*) from kpi.dq_flag)                        as dq_flags,
        (select count(*) from kpi.kpi_snapshot where status <> 'superseded') as snapshot_rows
)

select jsonb_pretty(jsonb_build_object(
    'generated_from', 'Program KPI schema demo dataset (2023-2025)',
    'institution',    (select name from kpi.institution limit 1),
    'years',          (select jsonb_agg(fiscal_year order by fiscal_year) from years),
    'counts',         (select to_jsonb(c) from counts c),
    'scorecard',      (select coalesce(jsonb_agg(to_jsonb(s) order by s.fiscal_year, s.category_order, s.kpi_code), '[]'::jsonb) from scorecard s),
    'categories',     (select coalesce(jsonb_agg(to_jsonb(c) order by c.fiscal_year, c.sort_order), '[]'::jsonb) from categories c),
    'programs',       (select coalesce(jsonb_agg(to_jsonb(p) order by p.fiscal_year, p.program_code, p.kpi_code), '[]'::jsonb) from programs p),
    'female_share',   (select coalesce(jsonb_agg(to_jsonb(f) order by f.fiscal_year, f.parent_kpi_code), '[]'::jsonb) from female_share f),
    'geography',      (select coalesce(jsonb_agg(to_jsonb(g) order by g.fiscal_year, g.country_name), '[]'::jsonb) from geography g),
    'dq_dimensions',  (select coalesce(jsonb_agg(to_jsonb(d) order by d.dimension), '[]'::jsonb) from dq_dimensions d),
    'dq_flags',       (select coalesce(jsonb_agg(to_jsonb(d)), '[]'::jsonb) from dq_flags d),
    'ingestion',      (select coalesce(jsonb_agg(to_jsonb(i)), '[]'::jsonb) from ingestion i),
    'lineage',        (select coalesce(jsonb_agg(to_jsonb(l)), '[]'::jsonb) from lineage l),
    'dedup',          (select coalesce(jsonb_agg(to_jsonb(d) order by d.fiscal_year, d.kpi_code), '[]'::jsonb) from dedup d)
));
