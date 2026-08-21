-- =============================================================================
-- 05_rollups.sql — the KPI calculation engine (framework sections 6, 11)
--
--   Step 4  Project Indicator validated        -> v_publishable_observation
--   Step 5  Project-level KPI contribution     -> v_project_indicator_value
--   Step 6  Aggregated across projects         -> v_program_kpi_value
--   Step 7  Program KPIs -> institutional KPI  -> v_institution_kpi_value
--
-- Two rules shape every view here (framework 6.2):
--
--   Percentages are never summed. Ratio and percentage indicators carry a
--   numerator and a denominator all the way up; each level recombines the parts
--   and divides once.
--
--   Distinct counts are never summed either. A student enrolled under two
--   projects is one student. For distinct_count indicators each level counts
--   entity rows directly rather than adding up the level below, so the same
--   entity collapses to one however many projects reported it.
-- =============================================================================

set search_path = kpi, public;

-- -----------------------------------------------------------------------------
-- Derivation helpers
-- -----------------------------------------------------------------------------

create or replace function kpi.compute_value(
    p_numerator   numeric,
    p_denominator numeric,
    p_value_type  kpi.value_type
)
returns numeric
language sql
immutable
as $$
    select case
        when p_denominator is null       then p_numerator
        when p_denominator = 0           then null
        when p_value_type = 'percentage' then 100.0 * p_numerator / p_denominator
        else p_numerator / p_denominator
    end;
$$;

-- Achievement against target, respecting indicator direction: for a
-- decrease-is-good KPI, coming in under target scores above 100%.
create or replace function kpi.achievement_pct(
    p_value     numeric,
    p_target    numeric,
    p_direction kpi.direction
)
returns numeric
language sql
immutable
as $$
    select case
        when p_value is null or p_target is null or p_target = 0 then null
        when p_direction = 'decrease' then 100.0 * (2 - p_value / p_target)
        else 100.0 * p_value / p_target
    end;
$$;

-- -----------------------------------------------------------------------------
-- Step 4 — Publishable observations
--
-- A value reaches the dashboard only if it is validated and carries no open
-- blocking data-quality flag. Flagged records stay in the table and in the
-- audit trail; they are excluded from the published figure, never deleted.
-- -----------------------------------------------------------------------------

create or replace view kpi.v_publishable_observation as
select o.*
from kpi.observation o
where o.status = 'validated'
  and not exists (
        select 1
          from kpi.dq_flag f
          join kpi.dq_rule r on r.id = f.dq_rule_id
         where f.observation_id = o.id
           and f.status in ('open', 'under_review')
           and r.blocks_publication);

comment on view kpi.v_publishable_observation is
    'Validated observations with no open blocking DQ flag — the only input to published KPI figures.';

-- -----------------------------------------------------------------------------
-- Period rollup — every period plus each of its ancestors
--
-- Projects report quarterly while the institution reports annually. Rather than
-- forcing everyone onto one cycle, an observation contributes to its own period
-- AND to every period above it, so FY2025 is computed from the same rows as
-- 2025-Q1..Q4 and can never disagree with them (framework 5.1, 8.1).
-- -----------------------------------------------------------------------------

create or replace view kpi.v_period_rollup as
with recursive ancestry as (
    select rp.id as period_id, rp.id as ancestor_period_id, rp.parent_period_id
      from kpi.reporting_period rp
    union all
    select a.period_id, parent.id, parent.parent_period_id
      from ancestry a
      join kpi.reporting_period parent on parent.id = a.parent_period_id
)
select period_id, ancestor_period_id from ancestry;

comment on view kpi.v_period_rollup is
    'Maps each reporting period to itself and to every period that contains it, so one observation serves quarterly and annual reporting.';

-- -----------------------------------------------------------------------------
-- Currently effective mappings (framework 10.1)
-- -----------------------------------------------------------------------------

create or replace view kpi.v_project_mapping as
select c.id as contribution_id, c.project_indicator_id, c.program_kpi_id,
       c.contribution_factor, c.weight, c.effective_from, c.effective_to
from kpi.project_indicator_contribution c
where c.mapping_status = 'validated';

create or replace view kpi.v_program_mapping as
select c.id as contribution_id, c.program_kpi_id, c.institution_kpi_id,
       c.contribution_factor, c.weight, c.effective_from, c.effective_to
from kpi.program_kpi_contribution c
where c.mapping_status = 'validated';

-- -----------------------------------------------------------------------------
-- Observation-grain fact view with every drill-down dimension attached
-- (framework 9.2 star schema). The dashboard slices this by country, commodity
-- or partner; the KPI views below are the official aggregates.
-- -----------------------------------------------------------------------------

create or replace view kpi.v_kpi_fact as
select
    o.id                       as observation_id,
    o.reporting_period_id,
    rp.fiscal_year,
    rp.period_type,
    inst.id                    as institution_id,
    prg.id                     as program_id,
    prj.id                     as project_id,
    wp.id                      as work_package_id,
    act.id                     as activity_id,
    pi.id                      as project_indicator_id,
    idef.id                    as indicator_definition_id,
    idef.code                  as indicator_code,
    cat.code                   as kpi_category_code,
    cat.name                   as kpi_category_name,
    o.country_id,
    o.location_id,
    o.commodity_id,
    o.partner_id,
    o.disaggregation_key,
    idef.value_type,
    idef.aggregation_method,
    o.numerator,
    o.denominator,
    o.conversion_factor,
    o.weight,
    o.observed_on,
    o.status
from kpi.v_publishable_observation o
join kpi.project_indicator pi        on pi.id = o.project_indicator_id
join kpi.project prj                 on prj.id = pi.project_id
join kpi.program prg                 on prg.id = prj.program_id
join kpi.institution inst            on inst.id = prg.institution_id
join kpi.indicator_definition idef   on idef.id = pi.indicator_definition_id
join kpi.reporting_period rp         on rp.id = o.reporting_period_id
left join kpi.kpi_category cat       on cat.id = idef.kpi_category_id
left join kpi.activity_result ar     on ar.id = o.activity_result_id
left join kpi.activity act           on act.id = ar.activity_id
left join kpi.work_package wp        on wp.id = coalesce(act.work_package_id, pi.work_package_id);

-- =============================================================================
-- Entity reach views — the basis of every distinct count
--
-- One row per (KPI, period, slice, canonical entity). Because these are "long"
-- rather than pre-aggregated, the same rows serve both the per-slice figure and
-- the overall total: an entity appearing in two slices is counted once in the
-- total without any special case. Merged duplicates resolve to their surviving
-- record here, so deduplication happens exactly once, in one place.
-- =============================================================================

create or replace view kpi.v_project_indicator_entity as
select distinct
    pi.id                              as project_indicator_id,
    pi.project_id,
    prj.program_id,
    prg.institution_id,
    pi.indicator_definition_id,
    pr.ancestor_period_id              as reporting_period_id,
    o.disaggregation_key,
    coalesce(e.merged_into_id, e.id)   as canonical_entity_id
from kpi.v_publishable_observation o
join kpi.v_period_rollup pr        on pr.period_id = o.reporting_period_id
join kpi.project_indicator pi      on pi.id = o.project_indicator_id
join kpi.project prj               on prj.id = pi.project_id
join kpi.program prg               on prg.id = prj.program_id
join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
join kpi.observation_entity oe     on oe.observation_id = o.id
join kpi.entity e                  on e.id = oe.entity_id
where idef.aggregation_method = 'distinct_count';

create or replace view kpi.v_program_kpi_entity as
select distinct
    pk.id                              as program_kpi_id,
    pk.program_id,
    prg.institution_id,
    pk.indicator_definition_id,
    pr.ancestor_period_id              as reporting_period_id,
    o.disaggregation_key,
    prj.id                             as project_id,
    coalesce(e.merged_into_id, e.id)   as canonical_entity_id
from kpi.program_kpi pk
join kpi.program prg               on prg.id = pk.program_id
join kpi.indicator_definition idef on idef.id = pk.indicator_definition_id
join kpi.v_project_mapping c       on c.program_kpi_id = pk.id
join kpi.project_indicator pi      on pi.id = c.project_indicator_id
join kpi.project prj               on prj.id = pi.project_id
join kpi.v_publishable_observation o on o.project_indicator_id = pi.id
join kpi.v_period_rollup pr        on pr.period_id = o.reporting_period_id
join kpi.reporting_period rp       on rp.id = pr.ancestor_period_id
join kpi.observation_entity oe     on oe.observation_id = o.id
join kpi.entity e                  on e.id = oe.entity_id
where pk.is_active
  and idef.aggregation_method = 'distinct_count'
  and (c.effective_from is null or rp.end_date   >= c.effective_from)
  and (c.effective_to   is null or rp.start_date <= c.effective_to);

create or replace view kpi.v_institution_kpi_entity as
select distinct
    ik.id                              as institution_kpi_id,
    ik.institution_id,
    ik.indicator_definition_id,
    pr.ancestor_period_id              as reporting_period_id,
    o.disaggregation_key,
    prj.program_id,
    coalesce(e.merged_into_id, e.id)   as canonical_entity_id
from kpi.institution_kpi ik
join kpi.indicator_definition idef on idef.id = ik.indicator_definition_id
join kpi.v_program_mapping pc      on pc.institution_kpi_id = ik.id
join kpi.v_project_mapping c       on c.program_kpi_id = pc.program_kpi_id
join kpi.project_indicator pi      on pi.id = c.project_indicator_id
join kpi.project prj               on prj.id = pi.project_id
join kpi.v_publishable_observation o on o.project_indicator_id = pi.id
join kpi.v_period_rollup pr        on pr.period_id = o.reporting_period_id
join kpi.reporting_period rp       on rp.id = pr.ancestor_period_id
join kpi.observation_entity oe     on oe.observation_id = o.id
join kpi.entity e                  on e.id = oe.entity_id
where ik.is_active
  and idef.aggregation_method = 'distinct_count'
  and (c.effective_from  is null or rp.end_date   >= c.effective_from)
  and (c.effective_to    is null or rp.start_date <= c.effective_to)
  and (pc.effective_from is null or rp.end_date   >= pc.effective_from)
  and (pc.effective_to   is null or rp.start_date <= pc.effective_to);

comment on view kpi.v_institution_kpi_entity is
    'Distinct entities reaching an institutional KPI. An ARI collaborating with three programs appears once.';

-- =============================================================================
-- Step 5 — Project-level KPI contribution
-- =============================================================================

create or replace view kpi.v_project_indicator_value as
-- Branch A: everything except distinct counts, aggregated from observations.
select
    pi.id                  as project_indicator_id,
    pi.project_id,
    prj.program_id,
    prg.institution_id,
    pi.indicator_definition_id,
    pr.ancestor_period_id  as reporting_period_id,
    o.disaggregation_key,
    idef.value_type,
    idef.aggregation_method,
    idef.direction,
    case idef.aggregation_method
        when 'average'          then avg(o.numerator * o.conversion_factor)
        when 'max'              then max(o.numerator * o.conversion_factor)
        when 'min'              then min(o.numerator * o.conversion_factor)
        when 'latest'           then (array_agg(o.numerator * o.conversion_factor
                                                order by o.observed_on desc, o.id desc))[1]
        when 'weighted_average' then sum(o.numerator * o.conversion_factor * o.weight)
                                     / nullif(sum(o.weight), 0)
        else                         sum(o.numerator * o.conversion_factor)
    end                    as numerator,
    case idef.aggregation_method
        when 'average'          then avg(o.denominator)
        when 'max'              then max(o.denominator)
        when 'min'              then min(o.denominator)
        when 'latest'           then (array_agg(o.denominator
                                                order by o.observed_on desc, o.id desc))[1]
        when 'weighted_average' then sum(o.denominator * o.weight) / nullif(sum(o.weight), 0)
        else                         sum(o.denominator)
    end                    as denominator,
    -- Carried upward so a weighted average stays weighted by the underlying
    -- data (trial or plot counts for KPI 9), not by the static mapping weight.
    sum(o.weight)          as total_weight,
    count(*)               as observation_count,
    max(o.observed_on)     as latest_observed_on,
    max(o.updated_at)      as last_updated_at
from kpi.v_publishable_observation o
join kpi.v_period_rollup pr        on pr.period_id = o.reporting_period_id
join kpi.project_indicator pi      on pi.id = o.project_indicator_id
join kpi.project prj               on prj.id = pi.project_id
join kpi.program prg               on prg.id = prj.program_id
join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
where idef.aggregation_method <> 'distinct_count'
group by pi.id, pi.project_id, prj.program_id, prg.institution_id,
         pi.indicator_definition_id, pr.ancestor_period_id, o.disaggregation_key,
         idef.value_type, idef.aggregation_method, idef.direction

union all

-- Branch B: distinct counts, from the entity reach view.
select
    v.project_indicator_id,
    v.project_id,
    v.program_id,
    v.institution_id,
    v.indicator_definition_id,
    v.reporting_period_id,
    v.disaggregation_key,
    idef.value_type,
    idef.aggregation_method,
    idef.direction,
    count(*)::numeric      as numerator,
    null::numeric          as denominator,
    count(*)::numeric      as total_weight,
    count(*)               as observation_count,
    null::date             as latest_observed_on,
    null::timestamptz      as last_updated_at
from kpi.v_project_indicator_entity v
join kpi.indicator_definition idef on idef.id = v.indicator_definition_id
group by v.project_indicator_id, v.project_id, v.program_id, v.institution_id,
         v.indicator_definition_id, v.reporting_period_id, v.disaggregation_key,
         idef.value_type, idef.aggregation_method, idef.direction;

comment on view kpi.v_project_indicator_value is
    'Step 5: publishable observations rolled to one value per project indicator, period and slice.';

create or replace view kpi.v_project_indicator_kpi as
select
    v.*,
    kpi.compute_value(v.numerator, v.denominator, v.value_type) as value,
    t.target_value,
    t.cumulative_target,
    kpi.achievement_pct(
        kpi.compute_value(v.numerator, v.denominator, v.value_type),
        t.target_value, v.direction) as achievement_pct
from kpi.v_project_indicator_value v
left join kpi.project_indicator_target t
       on t.project_indicator_id = v.project_indicator_id
      and t.reporting_period_id  = v.reporting_period_id
      and t.disaggregation_key   = v.disaggregation_key;

-- =============================================================================
-- Step 6 — Program KPI: contributions aggregated across projects
-- =============================================================================

create or replace view kpi.v_program_kpi_value as
select
    pk.id            as program_kpi_id,
    pk.program_id,
    prg.institution_id,
    pk.indicator_definition_id,
    v.reporting_period_id,
    v.disaggregation_key,
    idef.value_type,
    idef.aggregation_method,
    idef.direction,
    -- The effective weight of a child is its own accumulated data weight times
    -- the mapping weight, so KPI 9 stays weighted by trial counts across every
    -- level rather than degrading to a simple average of project figures.
    case idef.aggregation_method
        when 'weighted_average' then sum(v.numerator * c.contribution_factor
                                         * v.total_weight * c.weight)
                                     / nullif(sum(v.total_weight * c.weight), 0)
        when 'average' then avg(v.numerator * c.contribution_factor)
        when 'max'     then max(v.numerator * c.contribution_factor)
        when 'min'     then min(v.numerator * c.contribution_factor)
        when 'latest'  then (array_agg(v.numerator * c.contribution_factor
                                       order by v.latest_observed_on desc,
                                                v.project_indicator_id desc))[1]
        else                sum(v.numerator * c.contribution_factor)
    end              as numerator,
    case idef.aggregation_method
        when 'weighted_average' then sum(v.denominator * v.total_weight * c.weight)
                                     / nullif(sum(v.total_weight * c.weight), 0)
        when 'average' then avg(v.denominator)
        when 'max'     then max(v.denominator)
        when 'min'     then min(v.denominator)
        when 'latest'  then (array_agg(v.denominator
                                       order by v.latest_observed_on desc,
                                                v.project_indicator_id desc))[1]
        else                sum(v.denominator)
    end              as denominator,
    sum(v.total_weight * c.weight) as total_weight,
    count(distinct v.project_id) as contributing_project_count,
    sum(v.observation_count)     as observation_count,
    max(v.latest_observed_on)    as latest_observed_on,
    max(v.last_updated_at)       as last_updated_at
from kpi.program_kpi pk
join kpi.program prg               on prg.id = pk.program_id
join kpi.indicator_definition idef on idef.id = pk.indicator_definition_id
join kpi.v_project_mapping c       on c.program_kpi_id = pk.id
join kpi.v_project_indicator_value v on v.project_indicator_id = c.project_indicator_id
join kpi.reporting_period rp       on rp.id = v.reporting_period_id
where pk.is_active
  and idef.aggregation_method <> 'distinct_count'
  and (c.effective_from is null or rp.end_date   >= c.effective_from)
  and (c.effective_to   is null or rp.start_date <= c.effective_to)
group by pk.id, pk.program_id, prg.institution_id, pk.indicator_definition_id,
         v.reporting_period_id, v.disaggregation_key,
         idef.value_type, idef.aggregation_method, idef.direction

union all

-- A delivery partner trained by three projects in the program counts once here,
-- which summing the three project figures would not achieve.
select
    v.program_kpi_id,
    v.program_id,
    v.institution_id,
    v.indicator_definition_id,
    v.reporting_period_id,
    v.disaggregation_key,
    idef.value_type,
    idef.aggregation_method,
    idef.direction,
    count(distinct v.canonical_entity_id)::numeric,
    null::numeric,
    count(*)::numeric,
    count(distinct v.project_id),
    count(*),
    null::date,
    null::timestamptz
from kpi.v_program_kpi_entity v
join kpi.indicator_definition idef on idef.id = v.indicator_definition_id
group by v.program_kpi_id, v.program_id, v.institution_id, v.indicator_definition_id,
         v.reporting_period_id, v.disaggregation_key,
         idef.value_type, idef.aggregation_method, idef.direction;

comment on view kpi.v_program_kpi_value is
    'Step 6: project contributions aggregated into a program KPI, honouring mapping windows and de-duplicating entities.';

create or replace view kpi.v_program_kpi_scorecard as
select
    v.*,
    kpi.compute_value(v.numerator, v.denominator, v.value_type) as value,
    t.target_value,
    t.cumulative_target,
    kpi.achievement_pct(
        kpi.compute_value(v.numerator, v.denominator, v.value_type),
        t.target_value, v.direction) as achievement_pct
from kpi.v_program_kpi_value v
left join kpi.program_kpi_target t
       on t.program_kpi_id      = v.program_kpi_id
      and t.reporting_period_id = v.reporting_period_id
      and t.disaggregation_key  = v.disaggregation_key;

-- =============================================================================
-- Step 7 — Institutional KPI
-- =============================================================================

create or replace view kpi.v_institution_kpi_value as
select
    ik.id            as institution_kpi_id,
    ik.institution_id,
    ik.indicator_definition_id,
    v.reporting_period_id,
    v.disaggregation_key,
    idef.value_type,
    idef.aggregation_method,
    idef.direction,
    case idef.aggregation_method
        when 'weighted_average' then sum(v.numerator * c.contribution_factor
                                         * v.total_weight * c.weight)
                                     / nullif(sum(v.total_weight * c.weight), 0)
        when 'average' then avg(v.numerator * c.contribution_factor)
        when 'max'     then max(v.numerator * c.contribution_factor)
        when 'min'     then min(v.numerator * c.contribution_factor)
        when 'latest'  then (array_agg(v.numerator * c.contribution_factor
                                       order by v.latest_observed_on desc,
                                                v.program_kpi_id desc))[1]
        else                sum(v.numerator * c.contribution_factor)
    end              as numerator,
    case idef.aggregation_method
        when 'weighted_average' then sum(v.denominator * v.total_weight * c.weight)
                                     / nullif(sum(v.total_weight * c.weight), 0)
        when 'average' then avg(v.denominator)
        when 'max'     then max(v.denominator)
        when 'min'     then min(v.denominator)
        when 'latest'  then (array_agg(v.denominator
                                       order by v.latest_observed_on desc,
                                                v.program_kpi_id desc))[1]
        else                sum(v.denominator)
    end              as denominator,
    sum(v.total_weight * c.weight) as total_weight,
    count(distinct v.program_id) as contributing_program_count,
    sum(v.observation_count)     as observation_count,
    max(v.latest_observed_on)    as latest_observed_on,
    max(v.last_updated_at)       as last_updated_at
from kpi.institution_kpi ik
join kpi.indicator_definition idef on idef.id = ik.indicator_definition_id
join kpi.v_program_mapping c       on c.institution_kpi_id = ik.id
join kpi.v_program_kpi_value v     on v.program_kpi_id = c.program_kpi_id
join kpi.reporting_period rp       on rp.id = v.reporting_period_id
where ik.is_active
  and idef.aggregation_method <> 'distinct_count'
  and (c.effective_from is null or rp.end_date   >= c.effective_from)
  and (c.effective_to   is null or rp.start_date <= c.effective_to)
group by ik.id, ik.institution_id, ik.indicator_definition_id,
         v.reporting_period_id, v.disaggregation_key,
         idef.value_type, idef.aggregation_method, idef.direction

union all

select
    v.institution_kpi_id,
    v.institution_id,
    v.indicator_definition_id,
    v.reporting_period_id,
    v.disaggregation_key,
    idef.value_type,
    idef.aggregation_method,
    idef.direction,
    count(distinct v.canonical_entity_id)::numeric,
    null::numeric,
    count(*)::numeric,
    count(distinct v.program_id),
    count(*),
    null::date,
    null::timestamptz
from kpi.v_institution_kpi_entity v
join kpi.indicator_definition idef on idef.id = v.indicator_definition_id
group by v.institution_kpi_id, v.institution_id, v.indicator_definition_id,
         v.reporting_period_id, v.disaggregation_key,
         idef.value_type, idef.aggregation_method, idef.direction;

create or replace view kpi.v_institution_kpi_scorecard as
select
    v.*,
    kpi.compute_value(v.numerator, v.denominator, v.value_type) as value,
    t.target_value,
    t.cumulative_target,
    kpi.achievement_pct(
        kpi.compute_value(v.numerator, v.denominator, v.value_type),
        t.target_value, v.direction) as achievement_pct,
    b.code as performance_band
from kpi.v_institution_kpi_value v
left join kpi.institution_kpi_target t
       on t.institution_kpi_id  = v.institution_kpi_id
      and t.reporting_period_id = v.reporting_period_id
      and t.disaggregation_key  = v.disaggregation_key
left join kpi.performance_band b
       on kpi.achievement_pct(
              kpi.compute_value(v.numerator, v.denominator, v.value_type),
              t.target_value, v.direction)
          >= coalesce(b.min_achievement, -1e9)
      and kpi.achievement_pct(
              kpi.compute_value(v.numerator, v.denominator, v.value_type),
              t.target_value, v.direction)
          <  coalesce(b.max_achievement, 1e9);

-- =============================================================================
-- Totals across disaggregation slices
--
-- Additive and ratio indicators combine their slices: every observation carries
-- a complete set of its indicator's required dimensions, so the slices
-- partition the whole exactly, and ratios sum numerator and denominator before
-- dividing once.
--
-- Distinct counts are recounted from the entity reach views instead of summed,
-- because one entity can legitimately appear in more than one slice.
-- =============================================================================

create or replace view kpi.v_institution_kpi_total as
select
    v.institution_kpi_id,
    v.institution_id,
    v.indicator_definition_id,
    v.reporting_period_id,
    v.value_type,
    v.direction,
    sum(v.numerator)   as numerator,
    sum(v.denominator) as denominator,
    kpi.compute_value(sum(v.numerator), sum(v.denominator), v.value_type) as value
from kpi.v_institution_kpi_value v
where v.aggregation_method <> 'distinct_count'
group by v.institution_kpi_id, v.institution_id, v.indicator_definition_id,
         v.reporting_period_id, v.value_type, v.direction

union all

select
    v.institution_kpi_id,
    v.institution_id,
    v.indicator_definition_id,
    v.reporting_period_id,
    idef.value_type,
    idef.direction,
    count(distinct v.canonical_entity_id)::numeric,
    null::numeric,
    count(distinct v.canonical_entity_id)::numeric
from kpi.v_institution_kpi_entity v
join kpi.indicator_definition idef on idef.id = v.indicator_definition_id
group by v.institution_kpi_id, v.institution_id, v.indicator_definition_id,
         v.reporting_period_id, idef.value_type, idef.direction;

create or replace view kpi.v_program_kpi_total as
select
    v.program_kpi_id,
    v.program_id,
    v.institution_id,
    v.indicator_definition_id,
    v.reporting_period_id,
    v.value_type,
    v.direction,
    sum(v.numerator)   as numerator,
    sum(v.denominator) as denominator,
    kpi.compute_value(sum(v.numerator), sum(v.denominator), v.value_type) as value
from kpi.v_program_kpi_value v
where v.aggregation_method <> 'distinct_count'
group by v.program_kpi_id, v.program_id, v.institution_id, v.indicator_definition_id,
         v.reporting_period_id, v.value_type, v.direction

union all

select
    v.program_kpi_id,
    v.program_id,
    v.institution_id,
    v.indicator_definition_id,
    v.reporting_period_id,
    idef.value_type,
    idef.direction,
    count(distinct v.canonical_entity_id)::numeric,
    null::numeric,
    count(distinct v.canonical_entity_id)::numeric
from kpi.v_program_kpi_entity v
join kpi.indicator_definition idef on idef.id = v.indicator_definition_id
group by v.program_kpi_id, v.program_id, v.institution_id, v.indicator_definition_id,
         v.reporting_period_id, idef.value_type, idef.direction;

-- =============================================================================
-- Headline scorecards — the whole-KPI figure with target and traffic light
--
-- These read from the totals above rather than from the per-slice views. That
-- matters: KPIs 4-7 are always sex-disaggregated, so they have no unsliced row
-- and would disappear from any scorecard built on the sliced views.
-- =============================================================================

create or replace view kpi.v_institution_kpi_headline as
select
    t.institution_kpi_id,
    t.institution_id,
    t.indicator_definition_id,
    t.reporting_period_id,
    t.value_type,
    t.direction,
    t.numerator,
    t.denominator,
    t.value,
    tg.target_value,
    tg.cumulative_target,
    kpi.achievement_pct(t.value, tg.target_value, t.direction) as achievement_pct,
    b.code as performance_band
from kpi.v_institution_kpi_total t
left join kpi.institution_kpi_target tg
       on tg.institution_kpi_id  = t.institution_kpi_id
      and tg.reporting_period_id = t.reporting_period_id
      and tg.disaggregation_key  = ''
left join kpi.performance_band b
       on kpi.achievement_pct(t.value, tg.target_value, t.direction)
          >= coalesce(b.min_achievement, -1e9)
      and kpi.achievement_pct(t.value, tg.target_value, t.direction)
          <  coalesce(b.max_achievement, 1e9);

create or replace view kpi.v_program_kpi_headline as
select
    t.program_kpi_id,
    t.program_id,
    t.institution_id,
    t.indicator_definition_id,
    t.reporting_period_id,
    t.value_type,
    t.direction,
    t.numerator,
    t.denominator,
    t.value,
    tg.target_value,
    kpi.achievement_pct(t.value, tg.target_value, t.direction) as achievement_pct,
    b.code as performance_band
from kpi.v_program_kpi_total t
left join kpi.program_kpi_target tg
       on tg.program_kpi_id      = t.program_kpi_id
      and tg.reporting_period_id = t.reporting_period_id
      and tg.disaggregation_key  = ''
left join kpi.performance_band b
       on kpi.achievement_pct(t.value, tg.target_value, t.direction)
          >= coalesce(b.min_achievement, -1e9)
      and kpi.achievement_pct(t.value, tg.target_value, t.direction)
          <  coalesce(b.max_achievement, 1e9);

-- =============================================================================
-- Derived sub-indicators: the "a" percentages (KPI 4a, 5a, 6a, 7a)
--
-- The framework lists these as separate KPIs, but reporting them separately
-- invites disagreement with their parent. Deriving them from the parent's own
-- SEX disaggregation guarantees the share and the total always reconcile.
-- =============================================================================

create or replace view kpi.v_institution_female_share as
select
    v.institution_kpi_id,
    parent.code                                as parent_kpi_code,
    child.code                                 as share_kpi_code,
    v.reporting_period_id,
    sum(v.numerator) filter (where v.disaggregation_key like '%SEX=F%') as female_count,
    sum(v.numerator)                           as total_count,
    round(100.0 * sum(v.numerator) filter (where v.disaggregation_key like '%SEX=F%')
          / nullif(sum(v.numerator), 0), 1)    as female_share_pct
from kpi.v_institution_kpi_value v
join kpi.indicator_definition parent on parent.id = v.indicator_definition_id
join kpi.indicator_definition child  on child.parent_indicator_id = parent.id
group by v.institution_kpi_id, parent.code, child.code, v.reporting_period_id;

-- =============================================================================
-- Category reporting (framework section 4: the five KPI categories)
--
-- KPI values are NOT added across a category — the twenty indicators have
-- incompatible units, and summing papers with percentages would be meaningless.
-- What a category rolls up is performance: how many of its KPIs are on track,
-- at risk or off track, and the average achievement against target.
-- =============================================================================

create or replace view kpi.v_institution_category_performance as
select
    cat.id                as kpi_category_id,
    cat.code              as category_code,
    cat.name              as category_name,
    cat.sort_order,
    s.reporting_period_id,
    count(*)                                              as kpi_count,
    count(*) filter (where s.achievement_pct is not null)  as kpi_with_target_count,
    count(*) filter (where s.achievement_pct >= 90)        as on_track_count,
    count(*) filter (where s.achievement_pct >= 70
                       and s.achievement_pct <  90)        as at_risk_count,
    count(*) filter (where s.achievement_pct <  70)        as off_track_count,
    count(*) filter (where s.achievement_pct is null)      as no_target_count,
    round(avg(s.achievement_pct), 2)                       as avg_achievement_pct,
    -- Scorecard weights let a category score reflect KPI importance.
    round(sum(s.achievement_pct * ik.scorecard_weight)
          / nullif(sum(ik.scorecard_weight) filter (where s.achievement_pct is not null), 0),
          2)                                               as weighted_achievement_pct
from kpi.v_institution_kpi_headline s
join kpi.institution_kpi ik        on ik.id = s.institution_kpi_id
join kpi.indicator_definition idef on idef.id = s.indicator_definition_id
join kpi.kpi_category cat          on cat.id = idef.kpi_category_id
group by cat.id, cat.code, cat.name, cat.sort_order, s.reporting_period_id;

comment on view kpi.v_institution_category_performance is
    'Executive view: KPI counts by traffic-light state and average achievement, per source category.';

create or replace view kpi.v_program_category_performance as
select
    cat.id                as kpi_category_id,
    cat.code              as category_code,
    cat.name              as category_name,
    s.program_id,
    prg.name              as program_name,
    s.reporting_period_id,
    count(*)                                              as kpi_count,
    count(*) filter (where s.achievement_pct >= 90)        as on_track_count,
    count(*) filter (where s.achievement_pct >= 70
                       and s.achievement_pct <  90)        as at_risk_count,
    count(*) filter (where s.achievement_pct <  70)        as off_track_count,
    round(avg(s.achievement_pct), 2)                       as avg_achievement_pct
from kpi.v_program_kpi_headline s
join kpi.program prg               on prg.id = s.program_id
join kpi.indicator_definition idef on idef.id = s.indicator_definition_id
join kpi.kpi_category cat          on cat.id = idef.kpi_category_id
group by cat.id, cat.code, cat.name, s.program_id, prg.name, s.reporting_period_id;

-- The institutional scorecard laid out for display: categories in source order,
-- sub-indicators attached to their parent.
create or replace view kpi.v_institution_scorecard_display as
select
    cat.sort_order        as category_order,
    cat.code              as category_code,
    cat.name              as category_name,
    idef.code             as kpi_code,
    idef.name             as kpi_name,
    parent.code           as parent_kpi_code,
    idef.unit,
    idef.value_type,
    idef.aggregation_method,
    idef.is_indexed,
    idef.definition_status,
    s.reporting_period_id,
    round(s.value, idef.decimal_places)  as value,
    s.target_value,
    round(s.achievement_pct, 2)          as achievement_pct,
    s.performance_band
from kpi.v_institution_kpi_headline s
join kpi.indicator_definition idef  on idef.id = s.indicator_definition_id
left join kpi.indicator_definition parent on parent.id = idef.parent_indicator_id
left join kpi.kpi_category cat      on cat.id = idef.kpi_category_id;

-- =============================================================================
-- Cumulative series (framework 6.2)
--
-- For is_cumulative indicators the running total adds only each period's
-- increment to the prior cumulative value; history is never re-summed.
-- =============================================================================

create or replace view kpi.v_institution_kpi_cumulative as
select
    s.institution_kpi_id,
    s.indicator_definition_id,
    s.reporting_period_id,
    rp.period_type,
    rp.start_date,
    s.disaggregation_key,
    s.value                                     as period_value,
    sum(s.value) over (
        partition by s.institution_kpi_id, s.disaggregation_key, rp.period_type
        order by rp.start_date
        rows between unbounded preceding and current row)  as cumulative_value,
    s.cumulative_target
from kpi.v_institution_kpi_scorecard s
join kpi.reporting_period rp        on rp.id = s.reporting_period_id
join kpi.indicator_definition idef  on idef.id = s.indicator_definition_id
where idef.is_cumulative;

-- =============================================================================
-- Snapshots
--
-- The views above always reflect current data. A snapshot freezes what was
-- reported for a period, so a board pack published in April still reconciles
-- after a project restates its figures in June.
-- =============================================================================

create table kpi.kpi_snapshot (
    id                   bigint generated always as identity primary key,
    org_level            kpi.org_level not null,
    institution_kpi_id   bigint references kpi.institution_kpi (id) on delete cascade,
    program_kpi_id       bigint references kpi.program_kpi (id) on delete cascade,
    project_indicator_id bigint references kpi.project_indicator (id) on delete cascade,
    reporting_period_id  bigint not null references kpi.reporting_period (id) on delete cascade,
    disaggregation_key   text   not null default '',
    numerator            numeric(20, 6),
    denominator          numeric(20, 6),
    value                numeric(20, 6),
    target_value         numeric(20, 6),
    achievement_pct      numeric(12, 4),
    contributor_count    integer,
    observation_count    integer,
    status               kpi.approval_status not null default 'draft',
    computed_at          timestamptz not null default now(),
    computed_by          text,
    note                 text,
    constraint kpi_snapshot_one_owner_ck check (
        num_nonnulls(institution_kpi_id, program_kpi_id, project_indicator_id) = 1
    ),
    constraint kpi_snapshot_level_match_ck check (
        (org_level = 'institution' and institution_kpi_id   is not null) or
        (org_level = 'program'     and program_kpi_id       is not null) or
        (org_level = 'project'     and project_indicator_id is not null)
    )
);

-- At most one live snapshot per KPI, period and slice; earlier runs are superseded.
create unique index kpi_snapshot_live_uq on kpi.kpi_snapshot (
    coalesce(institution_kpi_id, 0),
    coalesce(program_kpi_id, 0),
    coalesce(project_indicator_id, 0),
    reporting_period_id,
    disaggregation_key
) where status <> 'superseded';

create index kpi_snapshot_period_idx on kpi.kpi_snapshot (reporting_period_id, org_level);

create or replace function kpi.take_snapshot(
    p_reporting_period_id bigint,
    p_computed_by text default current_user,
    p_status kpi.approval_status default 'draft',
    p_note text default null
)
returns integer
language plpgsql
as $$
declare
    v_rows integer := 0;
    v_inserted integer;
begin
    update kpi.kpi_snapshot
       set status = 'superseded'
     where reporting_period_id = p_reporting_period_id
       and status <> 'superseded';

    insert into kpi.kpi_snapshot (
        org_level, project_indicator_id, reporting_period_id, disaggregation_key,
        numerator, denominator, value, target_value, achievement_pct,
        contributor_count, observation_count, status, computed_by, note)
    select 'project', v.project_indicator_id, v.reporting_period_id, v.disaggregation_key,
           v.numerator, v.denominator, v.value, v.target_value, v.achievement_pct,
           null, v.observation_count, p_status, p_computed_by, p_note
      from kpi.v_project_indicator_kpi v
     where v.reporting_period_id = p_reporting_period_id;
    get diagnostics v_inserted = row_count;
    v_rows := v_rows + v_inserted;

    insert into kpi.kpi_snapshot (
        org_level, program_kpi_id, reporting_period_id, disaggregation_key,
        numerator, denominator, value, target_value, achievement_pct,
        contributor_count, observation_count, status, computed_by, note)
    select 'program', v.program_kpi_id, v.reporting_period_id, v.disaggregation_key,
           v.numerator, v.denominator, v.value, v.target_value, v.achievement_pct,
           v.contributing_project_count, v.observation_count, p_status, p_computed_by, p_note
      from kpi.v_program_kpi_scorecard v
     where v.reporting_period_id = p_reporting_period_id;
    get diagnostics v_inserted = row_count;
    v_rows := v_rows + v_inserted;

    insert into kpi.kpi_snapshot (
        org_level, institution_kpi_id, reporting_period_id, disaggregation_key,
        numerator, denominator, value, target_value, achievement_pct,
        contributor_count, observation_count, status, computed_by, note)
    select 'institution', v.institution_kpi_id, v.reporting_period_id, v.disaggregation_key,
           v.numerator, v.denominator, v.value, v.target_value, v.achievement_pct,
           v.contributing_program_count, v.observation_count, p_status, p_computed_by, p_note
      from kpi.v_institution_kpi_scorecard v
     where v.reporting_period_id = p_reporting_period_id;
    get diagnostics v_inserted = row_count;
    v_rows := v_rows + v_inserted;

    insert into kpi.audit_log (action, table_name, record_id, new_value, reason)
    values ('snapshot', 'kpi.kpi_snapshot', p_reporting_period_id::text,
            jsonb_build_object('rows', v_rows, 'period_id', p_reporting_period_id), p_note);

    return v_rows;
end;
$$;

comment on function kpi.take_snapshot is
    'Freezes computed values for one reporting period across all three levels; prior snapshots become superseded.';

-- =============================================================================
-- Lineage — "where did this number come from" (framework 7.1 drill-down)
-- =============================================================================

create or replace view kpi.v_kpi_lineage as
select
    ik.id       as institution_kpi_id,
    pk.id       as program_kpi_id,
    pi.id       as project_indicator_id,
    o.id        as observation_id,
    o.reporting_period_id,
    inst.name   as institution_name,
    prg.name    as program_name,
    prj.name    as project_name,
    act.name    as activity_name,
    idef.code   as indicator_code,
    idef.aggregation_method,
    o.disaggregation_key,
    o.numerator,
    o.denominator,
    o.conversion_factor,
    o.weight,
    c.contribution_factor  as project_to_program_factor,
    pc.contribution_factor as program_to_institution_factor,
    o.country_id,
    o.commodity_id,
    o.status,
    ev.uri      as evidence_uri
from kpi.observation o
join kpi.project_indicator pi      on pi.id = o.project_indicator_id
join kpi.project prj               on prj.id = pi.project_id
join kpi.program prg               on prg.id = prj.program_id
join kpi.institution inst          on inst.id = prg.institution_id
join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
left join kpi.activity_result ar   on ar.id = o.activity_result_id
left join kpi.activity act         on act.id = ar.activity_id
left join kpi.v_project_mapping c  on c.project_indicator_id = pi.id
left join kpi.program_kpi pk       on pk.id = c.program_kpi_id
left join kpi.v_program_mapping pc on pc.program_kpi_id = pk.id
left join kpi.institution_kpi ik   on ik.id = pc.institution_kpi_id
left join kpi.evidence ev          on ev.observation_id = o.id
                                   or ev.activity_result_id = o.activity_result_id;
