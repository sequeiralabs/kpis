-- =============================================================================
-- verify_demo.sql — assertions about the demo dataset in 07_demo_data.sql
--
-- Read-only. Confirms the dataset actually exercises what it claims to: three
-- years, all five categories, all twenty KPIs, every aggregation method, real
-- deduplication work, and problems in all seven data-quality dimensions.
-- =============================================================================

\set ON_ERROR_STOP on
set search_path = kpi, public;

create or replace function pg_temp.check(p_label text, p_actual anyelement, p_expected anyelement)
returns void language plpgsql as $$
begin
    if p_actual is distinct from p_expected then
        raise exception 'FAIL % — expected %, got %', p_label, p_expected, p_actual;
    end if;
    raise notice 'pass  %  = %', p_label, p_actual;
end $$;

create or replace function pg_temp.check_min(p_label text, p_actual bigint, p_min bigint)
returns void language plpgsql as $$
begin
    if p_actual < p_min then
        raise exception 'FAIL % — expected at least %, got %', p_label, p_min, p_actual;
    end if;
    raise notice 'pass  %  = %', p_label, p_actual;
end $$;

do $$
declare v_i bigint; v_n numeric;
begin
    -- ---- shape of the dataset ------------------------------------------
    select count(*) into v_i from kpi.institution;
    perform pg_temp.check('institutions (single-institution model)', v_i, 1::bigint);

    select count(*) into v_i from kpi.kpi_category;
    perform pg_temp.check('KPI categories', v_i, 5::bigint);

    select count(*) into v_i from kpi.indicator_definition;
    perform pg_temp.check('KPIs in the catalogue (20 plus 4 sub-indicators)', v_i, 24::bigint);

    select count(*) into v_i from kpi.institution_kpi;
    perform pg_temp.check('institutional KPIs instantiated', v_i, 24::bigint);

    select count(*) into v_i from kpi.program;
    perform pg_temp.check('programs', v_i, 5::bigint);

    select count(*) into v_i from kpi.project;
    perform pg_temp.check('projects', v_i, 16::bigint);

    -- ---- three years of data -------------------------------------------
    select count(distinct rp.fiscal_year) into v_i
      from kpi.observation o join kpi.reporting_period rp on rp.id = o.reporting_period_id;
    perform pg_temp.check('fiscal years with observations (2023-2025)', v_i, 3::bigint);

    select count(*) into v_i from kpi.observation;
    perform pg_temp.check_min('observations', v_i, 2000::bigint);

    -- ---- every category reports at institutional level ------------------
    select count(distinct cat.id) into v_i
      from kpi.v_institution_kpi_headline h
      join kpi.indicator_definition idef on idef.id = h.indicator_definition_id
      join kpi.kpi_category cat on cat.id = idef.kpi_category_id
      join kpi.reporting_period rp on rp.id = h.reporting_period_id
     where rp.code = 'FY2025';
    perform pg_temp.check('categories reporting a FY2025 value', v_i, 5::bigint);

    -- ---- every aggregation method is exercised --------------------------
    select count(distinct idef.aggregation_method) into v_i
      from kpi.v_institution_kpi_value v
      join kpi.indicator_definition idef on idef.id = v.indicator_definition_id;
    perform pg_temp.check_min('distinct aggregation methods in use', v_i, 4::bigint);

    -- ---- deduplication is doing real work -------------------------------
    -- The institutional distinct count must be strictly less than the sum of
    -- the program counts, or the entity registry is not earning its place.
    select h.value into v_n
      from kpi.v_institution_kpi_headline h
      join kpi.indicator_definition i on i.id = h.indicator_definition_id
      join kpi.reporting_period rp on rp.id = h.reporting_period_id
     where i.code = 'KPI_6' and rp.code = 'FY2025';

    select sum(p.value) into v_i
      from kpi.v_program_kpi_headline p
      join kpi.indicator_definition i on i.id = p.indicator_definition_id
      join kpi.reporting_period rp on rp.id = p.reporting_period_id
     where i.code = 'KPI_6' and rp.code = 'FY2025';

    if v_n >= v_i then
        raise exception
            'FAIL deduplication — institutional KPI 6 (%) is not below the sum of program counts (%)',
            v_n, v_i;
    end if;
    raise notice 'pass  KPI 6 dedup: institution % vs sum of programs %', v_n, v_i;

    -- ---- annual figures agree with their quarters -----------------------
    -- FY2025 must equal the sum of its four quarters for an additive KPI,
    -- because both come from the same observations.
    select h.value into v_n
      from kpi.v_institution_kpi_headline h
      join kpi.indicator_definition i on i.id = h.indicator_definition_id
      join kpi.reporting_period rp on rp.id = h.reporting_period_id
     where i.code = 'KPI_1' and rp.code = 'FY2025';

    select sum(h.value) into v_i
      from kpi.v_institution_kpi_headline h
      join kpi.indicator_definition i on i.id = h.indicator_definition_id
      join kpi.reporting_period rp on rp.id = h.reporting_period_id
     where i.code = 'KPI_1' and rp.fiscal_year = 2025 and rp.period_type = 'quarter';
    perform pg_temp.check('FY2025 KPI 1 equals the sum of its quarters', v_n, v_i::numeric);

    -- ---- data quality across all seven dimensions -----------------------
    select count(distinct r.dimension) into v_i
      from kpi.dq_flag f join kpi.dq_rule r on r.id = f.dq_rule_id;
    perform pg_temp.check('data-quality dimensions with flags', v_i, 7::bigint);

    select count(*) into v_i from kpi.dq_flag f
      join kpi.dq_rule r on r.id = f.dq_rule_id
     where r.blocks_publication and f.status in ('open', 'under_review');
    perform pg_temp.check_min('blocking flags suppressing a figure', v_i, 1::bigint);

    -- A blocked observation must be absent from the publishable set.
    select count(*) into v_i
      from kpi.observation o
     where o.status = 'validated'
       and not exists (select 1 from kpi.v_publishable_observation p where p.id = o.id);
    perform pg_temp.check_min('validated observations withheld by a blocking flag', v_i, 1::bigint);

    -- ---- uniqueness: merges and open candidates -------------------------
    select count(*) into v_i from kpi.entity where merged_into_id is not null;
    perform pg_temp.check_min('entities merged as duplicates', v_i, 3::bigint);

    select count(*) into v_i from kpi.entity_duplicate_candidate where status = 'open';
    perform pg_temp.check_min('duplicate candidates awaiting review', v_i, 5::bigint);

    -- ---- staging: invalid records never became observations -------------
    select count(*) into v_i from kpi.staging_record
     where process_status in ('flagged', 'rejected');
    perform pg_temp.check_min('raw records held in staging after validation', v_i, 15::bigint);

    -- ---- versioned mappings ---------------------------------------------
    select count(*) into v_i from kpi.project_indicator_contribution
     where mapping_status = 'retired';
    perform pg_temp.check_min('retired mappings kept as history', v_i, 1::bigint);

    -- ---- snapshots -------------------------------------------------------
    select count(*) into v_i from kpi.kpi_snapshot where status <> 'superseded';
    perform pg_temp.check_min('live snapshot rows', v_i, 100::bigint);

    select count(distinct org_level) into v_i from kpi.kpi_snapshot;
    perform pg_temp.check('snapshot covers all three levels', v_i, 3::bigint);

    -- ---- targets deliberately missing for two categories ----------------
    select count(*) into v_i
      from kpi.v_institution_kpi_headline h
      join kpi.indicator_definition idef on idef.id = h.indicator_definition_id
      join kpi.kpi_category cat on cat.id = idef.kpi_category_id
      join kpi.reporting_period rp on rp.id = h.reporting_period_id
     where rp.code = 'FY2025' and h.target_value is null
       and cat.code in ('RECOGNITION', 'SOCIETY_INCLUSION');
    perform pg_temp.check_min('FY2025 KPIs with no target supplied', v_i, 5::bigint);

    -- ---- nothing is silently unattributed --------------------------------
    select count(*) into v_i
      from kpi.project_indicator pi
     where not exists (select 1 from kpi.project_indicator_contribution c
                        where c.project_indicator_id = pi.id);
    perform pg_temp.check('project indicators with no mapping at all', v_i, 0::bigint);

    raise notice '---';
    raise notice 'demo dataset verified.';
end $$;
