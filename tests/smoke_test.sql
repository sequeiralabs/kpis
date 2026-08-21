-- =============================================================================
-- smoke_test.sql — end-to-end exercise of the result chain
--
-- Builds a small but adversarial dataset and asserts the answers, focusing on
-- the traps the framework warns about in section 6.2:
--   * the same delivery partner trained by two projects and two programs
--   * a percentage KPI that must not be summed across projects
--   * a weighted average across crops
--   * a latest-status compliance rate
--   * a blocking data-quality flag suppressing a value
--   * required disaggregation and entity-count contracts being enforced
--
-- Runs against its own institution, programs and projects, so it is safe
-- whether or not the demo data in 07 is loaded. Wrapped in a transaction that
-- rolls back, leaving the database exactly as it found it.
-- =============================================================================

\set ON_ERROR_STOP on
set search_path = kpi, public;

begin;

-- -----------------------------------------------------------------------------
-- Fixture: 2 programs, 3 projects, 1 quarter
-- -----------------------------------------------------------------------------

insert into kpi.institution (code, name, description)
values ('TEST-INST', 'Smoke Test Institution', 'Isolated fixture for the smoke test.');

insert into kpi.program (institution_id, code, name, start_date, end_date)
select i.id, v.code, v.name, date '2024-01-01', date '2030-12-31'
from kpi.institution i,
     (values ('T-PRG-CASSAVA', 'Cassava Systems Program'),
             ('T-PRG-LEGUME',  'Legume Systems Program')) as v(code, name)
where i.code = 'TEST-INST';

insert into kpi.project (program_id, code, name, start_date, end_date, status)
select p.id, v.code, v.name, date '2025-01-01', date '2029-12-31', 'active'
from kpi.program p
join (values
    ('T-PRG-CASSAVA', 'T-PRJ-CAS-01', 'Cassava Seed Systems Nigeria'),
    ('T-PRG-CASSAVA', 'T-PRJ-CAS-02', 'Cassava Mechanisation DRC'),
    ('T-PRG-LEGUME',  'T-PRJ-LEG-01', 'Cowpea Scaling West Africa')
) as v(program_code, code, name) on v.program_code = p.code;

-- -----------------------------------------------------------------------------
-- KPI instances at all three levels, for four indicators with four different
-- aggregation methods.
-- -----------------------------------------------------------------------------

insert into kpi.institution_kpi (institution_id, indicator_definition_id, scorecard_weight)
select i.id, idef.id, 1
from kpi.institution i, kpi.indicator_definition idef
where i.code = 'TEST-INST' and idef.code in ('KPI_6', 'KPI_18', 'KPI_9', 'KPI_10');

insert into kpi.program_kpi (program_id, indicator_definition_id)
select p.id, idef.id
from kpi.program p, kpi.indicator_definition idef
where p.code in ('T-PRG-CASSAVA', 'T-PRG-LEGUME')
  and idef.code in ('KPI_6', 'KPI_18', 'KPI_9', 'KPI_10');

insert into kpi.project_indicator (project_id, indicator_definition_id, data_source)
select prj.id, idef.id, 'activity_rollup'
from kpi.project prj, kpi.indicator_definition idef
where prj.code in ('T-PRJ-CAS-01', 'T-PRJ-CAS-02', 'T-PRJ-LEG-01')
  and idef.code in ('KPI_6', 'KPI_18', 'KPI_9', 'KPI_10');

-- Validated mappings, project -> program -> institution.
insert into kpi.project_indicator_contribution
    (project_indicator_id, program_kpi_id, mapping_status, validated_by, validated_at)
select pi.id, pk.id, 'validated', 'melia.test', now()
from kpi.project_indicator pi
join kpi.project prj on prj.id = pi.project_id
join kpi.program prg on prg.id = prj.program_id
join kpi.institution inst on inst.id = prg.institution_id and inst.code = 'TEST-INST'
join kpi.program_kpi pk
  on pk.program_id = prj.program_id
 and pk.indicator_definition_id = pi.indicator_definition_id;

insert into kpi.program_kpi_contribution
    (program_kpi_id, institution_kpi_id, mapping_status, validated_by, validated_at)
select pk.id, ik.id, 'validated', 'melia.test', now()
from kpi.program_kpi pk
join kpi.program prg on prg.id = pk.program_id
join kpi.institution inst on inst.id = prg.institution_id and inst.code = 'TEST-INST'
join kpi.institution_kpi ik
  on ik.institution_id = prg.institution_id
 and ik.indicator_definition_id = pk.indicator_definition_id;

-- -----------------------------------------------------------------------------
-- Entities: one delivery partner is trained by all three projects, spanning
-- both programs. The correct institutional answer counts it once.
-- -----------------------------------------------------------------------------

insert into kpi.entity (entity_type, display_name, external_ref, external_ref_system)
values ('organization', 'T Green Harvest Cooperative', 'T-ROR-0001', 'ROR'),
       ('organization', 'T Sahel Agro Services',       'T-ROR-0002', 'ROR'),
       ('organization', 'T Delta Farmers Union',        'T-ROR-0003', 'ROR'),
       ('organization', 'T Green Harvest Co-op Ltd',    'T-ROR-0009', 'ROR');

-- The fourth record is the same organisation under a different name, merged
-- into the first. Distinct counts must follow the merge.
update kpi.entity
   set merged_into_id = (select id from kpi.entity where external_ref = 'T-ROR-0001'),
       merged_at = now(), merged_by = 'melia.test'
 where external_ref = 'T-ROR-0009';

-- -----------------------------------------------------------------------------
-- Observations for KPI 6 (distinct count of delivery partners, sex-disaggregated)
--
--   PRJ-CAS-01 trains Green Harvest + Sahel Agro   (2 partners)
--   PRJ-CAS-02 trains Green Harvest                 (1 partner, already counted)
--   PRJ-LEG-01 trains Green Harvest (as the merged duplicate) + Delta Farmers
--
--   Cassava program  = Green Harvest, Sahel Agro          -> 2
--   Legume program   = Green Harvest, Delta Farmers       -> 2
--   Institution      = Green Harvest, Sahel, Delta        -> 3   (not 2+2=4)
-- -----------------------------------------------------------------------------

create temporary table t_obs (project_code text, entity_ref text, sex text) on commit drop;
insert into t_obs values
    ('T-PRJ-CAS-01', 'T-ROR-0001', 'F'),
    ('T-PRJ-CAS-01', 'T-ROR-0002', 'M'),
    ('T-PRJ-CAS-02', 'T-ROR-0001', 'F'),
    ('T-PRJ-LEG-01', 'T-ROR-0009', 'F'),
    ('T-PRJ-LEG-01', 'T-ROR-0003', 'M');

do $$
declare
    r record;
    v_obs_id bigint;
    v_period bigint;
begin
    select id into v_period from kpi.reporting_period where code = '2026-Q1';

    -- One observation per (project, sex) slice, listing its entities.
    for r in
        select t.project_code, t.sex, count(*) as n, array_agg(t.entity_ref) as refs
          from t_obs t group by t.project_code, t.sex
    loop
        insert into kpi.observation (project_indicator_id, reporting_period_id,
                                     observed_on, numerator, status,
                                     validated_by, validated_at, recorded_by)
        select pi.id, v_period, date '2026-02-15', r.n, 'validated',
               'melia.test', now(), 'test'
          from kpi.project_indicator pi
          join kpi.project prj on prj.id = pi.project_id
          join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
         where prj.code = r.project_code and idef.code = 'KPI_6'
        returning id into v_obs_id;

        insert into kpi.observation_category (observation_id, dimension_id, dimension_category_id)
        select v_obs_id, d.id, c.id
          from kpi.dimension d
          join kpi.dimension_category c on c.dimension_id = d.id
         where d.code = 'SEX' and c.code = r.sex;

        insert into kpi.observation_entity (observation_id, entity_id)
        select v_obs_id, e.id from kpi.entity e where e.external_ref = any(r.refs);
    end loop;
end $$;

-- -----------------------------------------------------------------------------
-- KPI 18 — percentage of approved proposals with inclusion components.
-- Project figures are 3/10 (30%), 1/2 (50%), 4/8 (50%).
-- Averaging the percentages would give 43.3%. The correct answer recombines
-- the parts: 8/20 = 40%.
-- -----------------------------------------------------------------------------

insert into kpi.observation (project_indicator_id, reporting_period_id, observed_on,
                             numerator, denominator, status, validated_by, validated_at)
select pi.id, rp.id, date '2026-03-01', v.num, v.den, 'validated', 'melia.test', now()
from (values ('T-PRJ-CAS-01', 3, 10), ('T-PRJ-CAS-02', 1, 2), ('T-PRJ-LEG-01', 4, 8))
        as v(project_code, num, den)
join kpi.project prj on prj.code = v.project_code
join kpi.project_indicator pi on pi.project_id = prj.id
join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id and idef.code = 'KPI_18'
join kpi.reporting_period rp on rp.code = '2026-Q1';

-- -----------------------------------------------------------------------------
-- KPI 9 — weighted-average genetic gain across crops, weighted by trial count.
-- Cassava program: 2.0% over 100 trials and 0.5% over 300 trials.
-- The simple average is 1.25%; the weighted answer is (2*100 + 0.5*300)/400 = 0.875%.
-- -----------------------------------------------------------------------------

insert into kpi.observation (project_indicator_id, reporting_period_id, observed_on,
                             numerator, denominator, weight, status, validated_by, validated_at)
select pi.id, rp.id, date '2026-03-10', v.num, v.den, v.wt, 'validated', 'melia.test', now()
from (values ('T-PRJ-CAS-01', 2.0, 100.0, 100.0), ('T-PRJ-CAS-02', 0.5, 100.0, 300.0))
        as v(project_code, num, den, wt)
join kpi.project prj on prj.code = v.project_code
join kpi.project_indicator pi on pi.project_id = prj.id
join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id and idef.code = 'KPI_9'
join kpi.reporting_period rp on rp.code = '2026-Q1';

-- -----------------------------------------------------------------------------
-- KPI 10 — Crop Trust compliance, a latest-status indicator.
-- Two observations for the same project: 80% in January, 100% in March.
-- The answer is 100%, not 180% and not 90%.
-- -----------------------------------------------------------------------------

insert into kpi.observation (project_indicator_id, reporting_period_id, observed_on,
                             numerator, denominator, status, validated_by, validated_at,
                             activity_result_id)
select pi.id, rp.id, v.on_date, v.num, 100.0, 'validated', 'melia.test', now(), null
from (values ('T-PRJ-CAS-01', date '2026-01-20', 80.0)) as v(project_code, on_date, num)
join kpi.project prj on prj.code = v.project_code
join kpi.project_indicator pi on pi.project_id = prj.id
join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id and idef.code = 'KPI_10'
join kpi.reporting_period rp on rp.code = '2026-Q1';

-- The second reading needs a distinct slice key or it collides with the first
-- on the direct-entry unique index, so it is recorded against an activity.
insert into kpi.activity (project_id, code, name, status, actual_start, actual_end)
select prj.id, 'T-ACT-COMPLIANCE', 'Crop Trust compliance audit', 'completed',
       date '2026-03-01', date '2026-03-05'
from kpi.project prj where prj.code = 'T-PRJ-CAS-01';

insert into kpi.activity_result (activity_id, reporting_period_id, result_date,
                                 title, status, validated_by, validated_at)
select a.id, rp.id, date '2026-03-05', 'March compliance audit', 'validated', 'melia.test', now()
from kpi.activity a, kpi.reporting_period rp
where a.code = 'T-ACT-COMPLIANCE' and rp.code = '2026-Q1';

insert into kpi.observation (project_indicator_id, reporting_period_id, activity_result_id,
                             observed_on, numerator, denominator, status,
                             validated_by, validated_at)
select pi.id, rp.id, ar.id, date '2026-03-05', 100.0, 100.0, 'validated', 'melia.test', now()
from kpi.project_indicator pi
join kpi.project prj on prj.id = pi.project_id and prj.code = 'T-PRJ-CAS-01'
join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id and idef.code = 'KPI_10'
join kpi.reporting_period rp on rp.code = '2026-Q1'
join kpi.activity a on a.code = 'T-ACT-COMPLIANCE'
join kpi.activity_result ar on ar.activity_id = a.id;

-- -----------------------------------------------------------------------------
-- Assertions
-- -----------------------------------------------------------------------------

create or replace function pg_temp.assert_eq(p_label text, p_actual numeric, p_expected numeric)
returns void language plpgsql as $$
begin
    if p_actual is distinct from p_expected then
        raise exception 'FAIL % — expected %, got %', p_label, p_expected, p_actual;
    end if;
    raise notice 'pass  %  = %', p_label, p_actual;
end $$;

do $$
declare v numeric;
begin
    -- KPI 6: program-level distinct counts
    select t.value into v
      from kpi.v_program_kpi_total t
      join kpi.program p on p.id = t.program_id
      join kpi.indicator_definition i on i.id = t.indicator_definition_id
     where p.code = 'T-PRG-CASSAVA' and i.code = 'KPI_6';
    perform pg_temp.assert_eq('KPI 6 / Cassava program distinct partners', v, 2);

    select t.value into v
      from kpi.v_program_kpi_total t
      join kpi.program p on p.id = t.program_id
      join kpi.indicator_definition i on i.id = t.indicator_definition_id
     where p.code = 'T-PRG-LEGUME' and i.code = 'KPI_6';
    perform pg_temp.assert_eq('KPI 6 / Legume program distinct partners', v, 2);

    -- The headline test: 2 + 2 would be 4; the right answer is 3.
    select t.value into v
      from kpi.v_institution_kpi_total t
      join kpi.indicator_definition i on i.id = t.indicator_definition_id
      join kpi.institution inst on inst.id = t.institution_id and inst.code = 'TEST-INST'
     where i.code = 'KPI_6';
    perform pg_temp.assert_eq('KPI 6 / institution distinct partners (not 4)', v, 3);

    -- The merged duplicate did not inflate the count.
    select count(*)::numeric into v
      from kpi.v_institution_kpi_entity e
      join kpi.indicator_definition i on i.id = e.indicator_definition_id
      join kpi.institution inst on inst.id = e.institution_id and inst.code = 'TEST-INST'
      join kpi.reporting_period rp on rp.id = e.reporting_period_id and rp.code = '2026-Q1'
     where i.code = 'KPI_6';
    perform pg_temp.assert_eq('KPI 6 / entity reach rows across slices', v, 4);

    -- KPI 18: percentage recombined from parts, not averaged.
    select round(t.value, 4) into v
      from kpi.v_institution_kpi_total t
      join kpi.indicator_definition i on i.id = t.indicator_definition_id
      join kpi.institution inst on inst.id = t.institution_id and inst.code = 'TEST-INST'
     where i.code = 'KPI_18';
    perform pg_temp.assert_eq('KPI 18 / institution percentage (8/20, not avg 43.3)', v, 40.0000);

    -- KPI 9: weighted average across crops.
    select round(s.numerator, 4) into v
      from kpi.v_program_kpi_scorecard s
      join kpi.program p on p.id = s.program_id
      join kpi.indicator_definition i on i.id = s.indicator_definition_id
     where p.code = 'T-PRG-CASSAVA' and i.code = 'KPI_9';
    perform pg_temp.assert_eq('KPI 9 / weighted gain (not simple avg 1.25)', v, 0.8750);

    -- KPI 10: latest status wins.
    select round(s.value, 4) into v
      from kpi.v_project_indicator_kpi s
      join kpi.project prj on prj.id = s.project_id
      join kpi.indicator_definition i on i.id = s.indicator_definition_id
     where prj.code = 'T-PRJ-CAS-01' and i.code = 'KPI_10';
    perform pg_temp.assert_eq('KPI 10 / latest compliance reading', v, 100.0000);

    -- Female share derived from the parent's own disaggregation. Of the three
    -- distinct partners, Green Harvest is the only one in the F slice, so the
    -- share is 1/3 — it counts partners, not the five observation rows.
    select f.female_share_pct into v
      from kpi.v_institution_female_share f
      join kpi.institution_kpi ik on ik.id = f.institution_kpi_id
      join kpi.institution inst on inst.id = ik.institution_id and inst.code = 'TEST-INST'
     where f.parent_kpi_code = 'KPI_6';
    perform pg_temp.assert_eq('KPI 6a / female share derived from KPI 6', v, 33.3);
end $$;

-- -----------------------------------------------------------------------------
-- A blocking data-quality flag must suppress the value it covers.
-- -----------------------------------------------------------------------------

do $$
declare
    v_before numeric; v_after numeric; v_obs bigint;
begin
    select t.value into v_before
      from kpi.v_institution_kpi_total t
      join kpi.indicator_definition i on i.id = t.indicator_definition_id
      join kpi.institution inst on inst.id = t.institution_id and inst.code = 'TEST-INST'
     where i.code = 'KPI_18';

    select o.id into v_obs
      from kpi.observation o
      join kpi.project_indicator pi on pi.id = o.project_indicator_id
      join kpi.indicator_definition i on i.id = pi.indicator_definition_id
      join kpi.project prj on prj.id = pi.project_id
     where i.code = 'KPI_18' and prj.code = 'T-PRJ-LEG-01';

    insert into kpi.dq_flag (dq_rule_id, observation_id, severity, detail)
    select r.id, v_obs, 'error', 'Denominator disputed by MELIA review'
      from kpi.dq_rule r where r.code = 'PCT_RANGE';

    select t.value into v_after
      from kpi.v_institution_kpi_total t
      join kpi.indicator_definition i on i.id = t.indicator_definition_id
      join kpi.institution inst on inst.id = t.institution_id and inst.code = 'TEST-INST'
     where i.code = 'KPI_18';

    -- 8/20 = 40% before; with the 4/8 observation suppressed, 4/12 = 33.33%.
    perform pg_temp.assert_eq('KPI 18 / before flag', round(v_before, 2), 40.00);
    perform pg_temp.assert_eq('KPI 18 / flagged observation suppressed',
                              round(v_after, 2), 33.33);

    -- Resolving the flag restores the value; the record was never deleted.
    update kpi.dq_flag set status = 'resolved', resolved_at = now(), resolved_by = 'melia.test'
     where observation_id = v_obs;

    select t.value into v_after
      from kpi.v_institution_kpi_total t
      join kpi.indicator_definition i on i.id = t.indicator_definition_id
      join kpi.institution inst on inst.id = t.institution_id and inst.code = 'TEST-INST'
     where i.code = 'KPI_18';
    perform pg_temp.assert_eq('KPI 18 / restored after resolution', round(v_after, 2), 40.00);
end $$;

-- -----------------------------------------------------------------------------
-- Contract enforcement: each of these must be rejected.
-- -----------------------------------------------------------------------------

do $$
declare
    v_pi bigint; v_period bigint; v_ok boolean;
begin
    select rp.id into v_period from kpi.reporting_period rp where rp.code = '2026-Q1';

    -- Missing the required SEX disaggregation on a KPI 6 observation.
    select pi.id into v_pi
      from kpi.project_indicator pi
      join kpi.project prj on prj.id = pi.project_id and prj.code = 'T-PRJ-CAS-01'
      join kpi.indicator_definition i on i.id = pi.indicator_definition_id and i.code = 'KPI_6';

    v_ok := false;
    begin
        insert into kpi.observation (project_indicator_id, reporting_period_id,
                                     observed_on, numerator, status)
        values (v_pi, v_period, date '2026-02-01', 5, 'draft');
        -- Constraint triggers are deferred, so force the check now.
        set constraints all immediate;
    exception when others then
        v_ok := true;
        raise notice 'pass  rejected: %', replace(sqlerrm, E'\n', ' ');
    end;
    if not v_ok then raise exception 'FAIL missing required dimension was accepted'; end if;
end $$;

do $$
declare v_ok boolean := false;
begin
    -- A project indicator contributing to another program's KPI.
    begin
        insert into kpi.project_indicator_contribution (project_indicator_id, program_kpi_id)
        select pi.id, pk.id
          from kpi.project_indicator pi
          join kpi.project prj on prj.id = pi.project_id and prj.code = 'T-PRJ-LEG-01'
          join kpi.indicator_definition i on i.id = pi.indicator_definition_id and i.code = 'KPI_6'
          join kpi.program_kpi pk on pk.indicator_definition_id = i.id
          join kpi.program prg on prg.id = pk.program_id and prg.code = 'T-PRG-CASSAVA'
         limit 1;
    exception when others then
        v_ok := true;
        raise notice 'pass  rejected: %', replace(sqlerrm, E'\n', ' ');
    end;
    if not v_ok then raise exception 'FAIL cross-program mapping was accepted'; end if;
end $$;

do $$
declare v_ok boolean := false;
begin
    -- An attribution factor on a percentage indicator.
    begin
        insert into kpi.project_indicator_contribution
            (project_indicator_id, program_kpi_id, contribution_factor)
        select pi.id, pk.id, 0.5
          from kpi.project_indicator pi
          join kpi.project prj on prj.id = pi.project_id and prj.code = 'T-PRJ-CAS-01'
          join kpi.indicator_definition i on i.id = pi.indicator_definition_id and i.code = 'KPI_18'
          join kpi.program_kpi pk on pk.indicator_definition_id = i.id
          join kpi.program prg on prg.id = pk.program_id and prg.code = 'T-PRG-CASSAVA'
         limit 1;
    exception when others then
        v_ok := true;
        raise notice 'pass  rejected: %', replace(sqlerrm, E'\n', ' ');
    end;
    if not v_ok then raise exception 'FAIL attribution factor on a percentage was accepted'; end if;
end $$;

do $$
declare v_ok boolean := false;
begin
    -- Writing into a closed period. The period is closed here rather than
    -- assumed, so the test does not depend on which periods the demo data locks.
    update kpi.reporting_period set is_open = false where code = 'FY2025';

    begin
        insert into kpi.observation (project_indicator_id, reporting_period_id,
                                     observed_on, numerator, denominator, status)
        select pi.id, rp.id, date '2025-06-01', 1, 10, 'draft'
          from kpi.project_indicator pi
          join kpi.project prj on prj.id = pi.project_id and prj.code = 'T-PRJ-CAS-01'
          join kpi.indicator_definition i on i.id = pi.indicator_definition_id and i.code = 'KPI_18'
          join kpi.reporting_period rp on rp.code = 'FY2025';
    exception when others then
        v_ok := true;
        raise notice 'pass  rejected: %', replace(sqlerrm, E'\n', ' ');
    end;
    if not v_ok then raise exception 'FAIL write to closed period was accepted'; end if;
end $$;

-- -----------------------------------------------------------------------------
-- Snapshot round-trip
-- -----------------------------------------------------------------------------

do $$
declare v_period bigint; v_rows integer; v_snapshot numeric; v_live numeric;
begin
    select id into v_period from kpi.reporting_period where code = '2026-Q1';
    v_rows := kpi.take_snapshot(v_period, 'melia.test', 'validated', 'Q1 2026 board pack');
    raise notice 'pass  snapshot wrote % rows', v_rows;

    select s.value into v_snapshot
      from kpi.kpi_snapshot s
      join kpi.institution_kpi ik on ik.id = s.institution_kpi_id
      join kpi.institution inst on inst.id = ik.institution_id and inst.code = 'TEST-INST'
      join kpi.indicator_definition i on i.id = ik.indicator_definition_id
     where i.code = 'KPI_6' and s.disaggregation_key = 'SEX=F' and s.status <> 'superseded';

    select v.numerator into v_live
      from kpi.v_institution_kpi_value v
      join kpi.indicator_definition i on i.id = v.indicator_definition_id
      join kpi.institution inst on inst.id = v.institution_id and inst.code = 'TEST-INST'
     where i.code = 'KPI_6' and v.disaggregation_key = 'SEX=F';
    perform pg_temp.assert_eq('snapshot matches live view', v_snapshot, v_live);

    -- Restating a figure moves the live view but not the frozen snapshot.
    update kpi.observation o
       set numerator = 99
      from kpi.project_indicator pi, kpi.indicator_definition i, kpi.project prj
     where o.project_indicator_id = pi.id and pi.indicator_definition_id = i.id
       and pi.project_id = prj.id
       and i.code = 'KPI_18' and prj.code = 'T-PRJ-CAS-01';

    select s.value into v_snapshot
      from kpi.kpi_snapshot s
      join kpi.institution_kpi ik on ik.id = s.institution_kpi_id
      join kpi.institution inst on inst.id = ik.institution_id and inst.code = 'TEST-INST'
      join kpi.indicator_definition i on i.id = ik.indicator_definition_id
     where i.code = 'KPI_18' and s.disaggregation_key = '' and s.status <> 'superseded';
    perform pg_temp.assert_eq('snapshot survives a restatement', round(v_snapshot, 2), 40.00);
end $$;

-- -----------------------------------------------------------------------------
-- Category rollup and lineage produce rows
-- -----------------------------------------------------------------------------

do $$
declare v_categories integer; v_lineage integer;
begin
    select count(*) into v_categories
      from kpi.v_institution_category_performance c
      join kpi.institution inst on inst.code = 'TEST-INST';
    if v_categories = 0 then raise exception 'FAIL category performance view is empty'; end if;
    raise notice 'pass  category performance rows: %', v_categories;

    select count(*) into v_lineage
      from kpi.v_kpi_lineage
     where indicator_code = 'KPI_6' and institution_name = 'Smoke Test Institution';
    if v_lineage = 0 then raise exception 'FAIL lineage view is empty'; end if;
    raise notice 'pass  lineage rows for KPI 6: %', v_lineage;
end $$;

rollback;
