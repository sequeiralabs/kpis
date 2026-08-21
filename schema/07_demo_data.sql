-- =============================================================================
-- 07_demo_data.sql — a three-year demonstration dataset (2023-2025)
--
-- Exercises every part of the design:
--   * 5 programs, 16 projects, work packages, activities across 12 countries
--   * all 20 KPIs across all 5 categories, at all three levels
--   * every aggregation method: sum, distinct_count, ratio, weighted_average, latest
--   * entities shared across projects and programs, so distinct counts have
--     real deduplication work to do
--   * targets for 2023-2026 and a deliberate gap for 2025 on some KPIs
--   * seeded data-quality problems covering all seven quality dimensions
--
-- The figures are synthetic and illustrative. They are NOT the indexed values
-- from the 2025 source file, which the framework flags as of unconfirmed basis.
--
-- Load after 01-06. Reproducible: seeded pseudo-randomness, no clock reads in
-- the generated values.
-- =============================================================================

set search_path = kpi, public;

-- Deterministic pseudo-randomness. A live randomness source would make the
-- dataset differ between loads, so figures are derived from a hash of the row's
-- own coordinates instead: the same project, period and indicator always
-- produce the same number, on any machine, in any order.
create or replace function kpi.demo_random(p_key text)
returns numeric
language sql
immutable
as $$
    select (abs(('x' || substr(md5(p_key), 1, 8))::bit(32)::bigint) % 1000000)::numeric
           / 1000000.0;
$$;

comment on function kpi.demo_random is
    'Reproducible 0-1 value derived from a key. Demo data generation only; not used by the KPI engine.';

-- =============================================================================
-- 1. Programs, projects, work packages
-- =============================================================================

insert into kpi.program (institution_id, code, name, description, program_leader,
                         start_date, end_date, status)
select i.id, v.code, v.name, v.descr, v.leader, date '2022-01-01', date '2030-12-31', 'active'
from kpi.institution i
join (values
    ('PRG-CASSAVA', 'Cassava Systems Program',
     'Breeding, seed systems and postharvest for cassava.', 'Dr A. Adeyemi'),
    ('PRG-LEGUME',  'Legume Systems Program',
     'Cowpea and soybean genetic improvement and scaling.', 'Dr B. Ouedraogo'),
    ('PRG-BANANA',  'Banana and Plantain Systems Program',
     'Disease resistance and propagation for banana and plantain.', 'Dr C. Nkurunziza'),
    ('PRG-NRM',     'Natural Resource Management Program',
     'Soil health, climate adaptation and landscape management.', 'Dr D. Mwangi'),
    ('PRG-SOCIO',   'Social Science and Agribusiness Program',
     'Markets, gender, nutrition and policy engagement.', 'Dr E. Bello')
) as v(code, name, descr, leader) on true
where i.code = 'INST';

insert into kpi.project (program_id, code, name, project_manager, donor,
                         start_date, end_date, status, budget_amount, budget_currency)
select p.id, v.code, v.name, v.manager, v.donor,
       v.start_date, v.end_date, v.status::kpi.lifecycle_status, v.budget, 'USD'
from kpi.program p
join (values
    ('PRG-CASSAVA', 'PRJ-CAS-01', 'Cassava Seed Systems Nigeria',       'M. Okafor',   'BMGF',        date '2022-06-01', date '2026-05-31', 'active',    8400000),
    ('PRG-CASSAVA', 'PRJ-CAS-02', 'Cassava Mechanisation DRC',          'J. Kabila',   'USAID',       date '2023-01-01', date '2026-12-31', 'active',    5200000),
    ('PRG-CASSAVA', 'PRJ-CAS-03', 'Cassava Postharvest Ghana',          'K. Mensah',   'EU',          date '2022-01-01', date '2025-12-31', 'completed', 3100000),
    ('PRG-CASSAVA', 'PRJ-CAS-04', 'Cassava Breeding Acceleration',      'T. Adebayo',  'FCDO',       date '2023-04-01', date '2028-03-31', 'active',    9800000),
    ('PRG-LEGUME',  'PRJ-LEG-01', 'Cowpea Scaling West Africa',         'F. Traore',   'BMGF',        date '2022-01-01', date '2026-12-31', 'active',    6700000),
    ('PRG-LEGUME',  'PRJ-LEG-02', 'Soybean Value Chains Zambia',        'N. Banda',    'IFAD',        date '2023-07-01', date '2027-06-30', 'active',    4300000),
    ('PRG-LEGUME',  'PRJ-LEG-03', 'Legume Seed Certification Malawi',   'P. Phiri',    'EU',          date '2022-03-01', date '2025-02-28', 'completed', 2100000),
    ('PRG-BANANA',  'PRJ-BAN-01', 'Banana Wilt Management Uganda',      'S. Nakato',   'BMGF',        date '2022-01-01', date '2026-12-31', 'active',    5900000),
    ('PRG-BANANA',  'PRJ-BAN-02', 'Plantain Propagation Cameroon',      'L. Etoundi',  'AfDB',        date '2023-01-01', date '2027-12-31', 'active',    3800000),
    ('PRG-BANANA',  'PRJ-BAN-03', 'Banana Genomics Tanzania',           'R. Mushi',    'FCDO',       date '2024-01-01', date '2028-12-31', 'active',    4600000),
    ('PRG-NRM',     'PRJ-NRM-01', 'Soil Health Nigeria',                'A. Yusuf',    'GIZ',         date '2022-01-01', date '2026-12-31', 'active',    5400000),
    ('PRG-NRM',     'PRJ-NRM-02', 'Climate Adaptation Sahel',           'H. Diallo',   'GCF',         date '2023-01-01', date '2028-12-31', 'active',    7200000),
    ('PRG-NRM',     'PRJ-NRM-03', 'Landscape Restoration Kenya',        'W. Kamau',    'World Bank',  date '2022-09-01', date '2026-08-31', 'active',    4900000),
    ('PRG-SOCIO',   'PRJ-SOC-01', 'Agribusiness Incubation West Africa','O. Danjuma',  'AfDB',        date '2022-01-01', date '2026-12-31', 'active',    3600000),
    ('PRG-SOCIO',   'PRJ-SOC-02', 'Nutrition Pathways East Africa',     'G. Wanjiru',  'IFAD',        date '2023-01-01', date '2027-12-31', 'active',    4100000),
    ('PRG-SOCIO',   'PRJ-SOC-03', 'Policy Engagement Platform',         'V. Nwosu',    'BMGF',        date '2022-01-01', date '2027-12-31', 'active',    2800000)
) as v(program_code, code, name, manager, donor, start_date, end_date, status, budget)
  on v.program_code = p.code;

-- Countries and commodities per project.
insert into kpi.project_country (project_id, country_id)
select prj.id, c.id
from kpi.project prj
join (values
    ('PRJ-CAS-01','NG'), ('PRJ-CAS-02','CD'), ('PRJ-CAS-03','GH'), ('PRJ-CAS-04','NG'),
    ('PRJ-CAS-04','BJ'), ('PRJ-LEG-01','NG'), ('PRJ-LEG-01','GH'), ('PRJ-LEG-02','ZM'),
    ('PRJ-LEG-03','MW'), ('PRJ-BAN-01','UG'), ('PRJ-BAN-02','CM'), ('PRJ-BAN-03','TZ'),
    ('PRJ-NRM-01','NG'), ('PRJ-NRM-02','BJ'), ('PRJ-NRM-03','KE'), ('PRJ-SOC-01','NG'),
    ('PRJ-SOC-02','KE'), ('PRJ-SOC-02','TZ'), ('PRJ-SOC-03','NG'), ('PRJ-SOC-03','RW')
) as v(project_code, iso) on v.project_code = prj.code
join kpi.country c on c.iso3166_alpha2 = v.iso;

insert into kpi.project_commodity (project_id, commodity_id)
select prj.id, cm.id
from kpi.project prj
join (values
    ('PRJ-CAS-01','CASSAVA'), ('PRJ-CAS-02','CASSAVA'), ('PRJ-CAS-03','CASSAVA'),
    ('PRJ-CAS-04','CASSAVA'), ('PRJ-CAS-04','YAM'),
    ('PRJ-LEG-01','COWPEA'), ('PRJ-LEG-02','SOYBEAN'), ('PRJ-LEG-03','COWPEA'),
    ('PRJ-BAN-01','BANANA'), ('PRJ-BAN-02','BANANA'), ('PRJ-BAN-03','BANANA'),
    ('PRJ-NRM-01','MAIZE'), ('PRJ-NRM-02','CROSS'), ('PRJ-NRM-03','CROSS'),
    ('PRJ-SOC-01','CROSS'), ('PRJ-SOC-02','CROSS'), ('PRJ-SOC-03','CROSS')
) as v(project_code, commodity) on v.project_code = prj.code
join kpi.commodity cm on cm.code = v.commodity;

-- Work packages on the larger projects.
insert into kpi.work_package (project_id, code, name, lead)
select prj.id, v.code, v.name, v.lead
from kpi.project prj
join (values
    ('PRJ-CAS-01', 'WP1', 'Breeder and foundation seed',    'M. Okafor'),
    ('PRJ-CAS-01', 'WP2', 'Community seed enterprises',     'I. Balogun'),
    ('PRJ-CAS-04', 'WP1', 'Genomic selection pipeline',     'T. Adebayo'),
    ('PRJ-CAS-04', 'WP2', 'Multi-location trials',          'C. Eze'),
    ('PRJ-LEG-01', 'WP1', 'Variety development',            'F. Traore'),
    ('PRJ-LEG-01', 'WP2', 'Partner capacity building',      'A. Kone'),
    ('PRJ-NRM-02', 'WP1', 'Climate-smart practices',        'H. Diallo'),
    ('PRJ-SOC-03', 'WP1', 'Policy dialogue and evidence',   'V. Nwosu')
) as v(project_code, code, name, lead) on v.project_code = prj.code;

-- =============================================================================
-- 2. KPI instances and mappings at all three levels
--
-- All 20 KPIs exist institutionally. Programs carry the KPIs relevant to their
-- mandate: research and training KPIs are institution-wide, while product
-- development sits with the breeding programs and inclusion with the social
-- science program.
-- =============================================================================

insert into kpi.institution_kpi (institution_id, indicator_definition_id,
                                 strategic_objective, scorecard_weight, responsible)
select i.id, idef.id,
       case cat.code
           when 'RESEARCH_OUTPUTS'    then 'Scientific excellence'
           when 'TRAINING_CAPACITY'   then 'Capacity of national systems'
           when 'PRODUCT_DEVELOPMENT' then 'Delivery of improved technologies'
           when 'RECOGNITION'         then 'Partnerships and influence'
           else                            'Inclusive and sustainable impact'
       end,
       case when idef.parent_indicator_id is null then 1.0 else 0.5 end,
       'MELIA'
from kpi.institution i
cross join kpi.indicator_definition idef
join kpi.kpi_category cat on cat.id = idef.kpi_category_id
where i.code = 'INST';

-- Which KPIs each program reports on.
create temporary table t_program_kpi (program_code text, kpi_code text);
insert into t_program_kpi
-- Research outputs and training: every program.
select p.code, k.code
from (values ('PRG-CASSAVA'),('PRG-LEGUME'),('PRG-BANANA'),('PRG-NRM'),('PRG-SOCIO')) as p(code)
cross join (values ('KPI_1'),('KPI_2'),('KPI_3'),('KPI_4'),('KPI_4A'),('KPI_5'),('KPI_5A'),
                   ('KPI_6'),('KPI_6A'),('KPI_7'),('KPI_7A'),('KPI_13'),('KPI_15'),('KPI_16')) as k(code)
union all
-- Product development: the three breeding programs.
select p.code, k.code
from (values ('PRG-CASSAVA'),('PRG-LEGUME'),('PRG-BANANA')) as p(code)
cross join (values ('KPI_8'),('KPI_9'),('KPI_10'),('KPI_11'),('KPI_12'),('KPI_14')) as k(code)
union all
-- Policy engagement and inclusion: social science, plus NRM for climate.
select 'PRG-SOCIO', k.code
from (values ('KPI_17'),('KPI_18'),('KPI_19'),('KPI_20'),('KPI_11'),('KPI_12'),('KPI_14')) as k(code)
union all
select 'PRG-NRM', k.code from (values ('KPI_17'),('KPI_19')) as k(code);

insert into kpi.program_kpi (program_id, indicator_definition_id, responsible)
select distinct p.id, idef.id, p.program_leader
from t_program_kpi t
join kpi.program p on p.code = t.program_code
join kpi.indicator_definition idef on idef.code = t.kpi_code;

-- Every project reports the KPIs its program carries, except that only projects
-- with a breeding work package report genetic gain.
insert into kpi.project_indicator (project_id, indicator_definition_id, data_source, responsible)
select prj.id, idef.id,
       case when idef.code in ('KPI_2', 'KPI_10') then 'direct_entry'::kpi.data_source
            else 'activity_rollup'::kpi.data_source end,
       prj.project_manager
from kpi.project prj
join kpi.program prg on prg.id = prj.program_id
join t_program_kpi t on t.program_code = prg.code
join kpi.indicator_definition idef on idef.code = t.kpi_code
where not (idef.code = 'KPI_9' and prj.code not in ('PRJ-CAS-04', 'PRJ-LEG-01', 'PRJ-BAN-03'))
  and not (idef.code = 'KPI_10' and prj.code not in ('PRJ-CAS-04', 'PRJ-BAN-03'));

-- Validated mappings, project -> program -> institution.
insert into kpi.project_indicator_contribution
    (project_indicator_id, program_kpi_id, mapping_status, validated_by, validated_at,
     effective_from, note)
select pi.id, pk.id, 'validated', 'melia.lead', timestamptz '2023-01-15 09:00+01',
       date '2023-01-01', 'Loaded during the 2023 results-framework alignment.'
from kpi.project_indicator pi
join kpi.project prj on prj.id = pi.project_id
join kpi.program_kpi pk on pk.program_id = prj.program_id
                       and pk.indicator_definition_id = pi.indicator_definition_id;

insert into kpi.program_kpi_contribution
    (program_kpi_id, institution_kpi_id, mapping_status, validated_by, validated_at,
     effective_from)
select pk.id, ik.id, 'validated', 'melia.lead', timestamptz '2023-01-15 09:00+01',
       date '2023-01-01'
from kpi.program_kpi pk
join kpi.program prg on prg.id = pk.program_id
join kpi.institution_kpi ik on ik.institution_id = prg.institution_id
                           and ik.indicator_definition_id = pk.indicator_definition_id;

-- =============================================================================
-- 3. Countable entities
--
-- Deliberately shared across projects: a student registered on two projects, a
-- delivery partner trained by three, an ARI collaborating with four programs.
-- Distinct counts must collapse these; summing project figures would not.
-- =============================================================================

-- Students (KPI 4) and their theses (KPI 5).
insert into kpi.entity (entity_type, display_name, external_ref, external_ref_system,
                        country_id, is_personal_data)
select 'person',
       'Student ' || lpad(n::text, 4, '0'),
       'INST-STU-' || lpad(n::text, 4, '0'), 'Institutional Registry',
       c.id, true
from generate_series(1, 420) as n
join lateral (
    select id from kpi.country order by (n * 7) % 12, id limit 1
) c on true;

insert into kpi.entity (entity_type, display_name, external_ref, external_ref_system)
select 'thesis',
       'Thesis ' || lpad(n::text, 4, '0'),
       'THESIS-' || lpad(n::text, 4, '0'), 'University Registry'
from generate_series(1, 260) as n;

-- National scientists trained (KPI 7).
insert into kpi.entity (entity_type, display_name, external_ref, external_ref_system,
                        country_id, is_personal_data)
select 'person',
       'Scientist ' || lpad(n::text, 4, '0'),
       'NARS-SCI-' || lpad(n::text, 4, '0'), 'NARS Registry',
       c.id, true
from generate_series(1, 310) as n
join lateral (select id from kpi.country order by (n * 5) % 12, id limit 1) c on true;

-- Partner organisations: delivery partners (KPI 6), ARIs (KPI 13),
-- scaling partners (KPI 14).
insert into kpi.partner (code, name, partner_type, country_id, external_ref)
select 'DP-' || lpad(n::text, 3, '0'),
       'Delivery Partner ' || lpad(n::text, 3, '0'),
       'NARS', c.id, 'ROR-DP-' || lpad(n::text, 3, '0')
from generate_series(1, 140) as n
join lateral (select id from kpi.country order by (n * 3) % 12, id limit 1) c on true;

insert into kpi.partner (code, name, partner_type, country_id, external_ref)
select 'ARI-' || lpad(n::text, 3, '0'),
       'Advanced Research Institute ' || lpad(n::text, 3, '0'),
       'ARI', null, 'ROR-ARI-' || lpad(n::text, 3, '0')
from generate_series(1, 45) as n;

insert into kpi.partner (code, name, partner_type, country_id, external_ref)
select 'SCP-' || lpad(n::text, 3, '0'),
       'Scaling Partner ' || lpad(n::text, 3, '0'),
       'Scaling', c.id, 'ROR-SCP-' || lpad(n::text, 3, '0')
from generate_series(1, 60) as n
join lateral (select id from kpi.country order by (n * 11) % 12, id limit 1) c on true;

insert into kpi.entity (entity_type, display_name, external_ref, external_ref_system,
                        country_id, partner_id)
select 'organization', p.name, p.external_ref, 'ROR', p.country_id, p.id
from kpi.partner p;

-- Varieties (KPI 8), innovations (KPI 11, 12), engagements (KPI 17),
-- proposals (KPI 18-20).
insert into kpi.entity (entity_type, display_name, external_ref, external_ref_system)
select 'variety', 'Variety ' || lpad(n::text, 3, '0'),
       'GAZ-' || lpad(n::text, 3, '0'), 'National Gazette'
from generate_series(1, 72) as n;

insert into kpi.entity (entity_type, display_name, external_ref, external_ref_system)
select 'innovation', 'Innovation ' || lpad(n::text, 3, '0'),
       'ECAT-' || lpad(n::text, 3, '0'), 'regional technology e-Catalogue'
from generate_series(1, 95) as n;

insert into kpi.entity (entity_type, display_name, external_ref, external_ref_system)
select 'engagement_event', 'Policy engagement ' || lpad(n::text, 3, '0'),
       'ENG-' || lpad(n::text, 3, '0'), 'Policy Register'
from generate_series(1, 180) as n;

-- =============================================================================
-- 4. Activities and observations, 2023-2025
--
-- One activity per project per quarter, with observations against the project's
-- indicators. Values trend gently upward year on year so the dashboard's trend
-- views have something to show.
-- =============================================================================

do $$
declare
    r_proj    record;
    r_period  record;
    r_ind     record;
    v_act     bigint;
    v_result  bigint;
    v_obs     bigint;
    v_growth  numeric;
    v_base    numeric;
    v_num     numeric;
    v_den     numeric;
    v_country bigint;
    v_commodity bigint;
    v_entity_ids bigint[];
    v_n       integer;
    v_sex     text;
    v_offset  integer := 0;
begin
for r_proj in
    select prj.id, prj.code, prj.start_date, prj.end_date, prj.program_id, prg.code as program_code
      from kpi.project prj join kpi.program prg on prg.id = prj.program_id
     order by prj.id
loop
    select pc.country_id into v_country
      from kpi.project_country pc where pc.project_id = r_proj.id order by pc.country_id limit 1;
    select pcm.commodity_id into v_commodity
      from kpi.project_commodity pcm where pcm.project_id = r_proj.id order by pcm.commodity_id limit 1;

    for r_period in
        select rp.id, rp.code, rp.start_date, rp.end_date, rp.fiscal_year
          from kpi.reporting_period rp
         where rp.period_type = 'quarter'
           and rp.fiscal_year between 2023 and 2025
           and rp.start_date >= r_proj.start_date
           and rp.end_date   <= coalesce(r_proj.end_date, date '2030-12-31')
         order by rp.start_date
    loop
        -- Growth factor: 2023 baseline, ~12% a year.
        v_growth := 1 + 0.12 * (r_period.fiscal_year - 2023);

        insert into kpi.activity (project_id, code, name, country_id, commodity_id,
                                  planned_start, planned_end, actual_start, actual_end,
                                  status, responsible)
        values (r_proj.id,
                'ACT-' || r_period.code,
                'Quarterly implementation ' || r_period.code,
                v_country, v_commodity,
                r_period.start_date, r_period.end_date,
                r_period.start_date, r_period.end_date,
                'completed', 'field team')
        returning id into v_act;

        insert into kpi.activity_result (activity_id, reporting_period_id, result_date,
                                         title, narrative, status, recorded_by,
                                         validated_by, validated_at)
        values (v_act, r_period.id, r_period.end_date,
                'Results for ' || r_period.code,
                'Consolidated quarterly results submitted by the project team.',
                'validated', 'project.officer',
                'melia.reviewer', r_period.end_date + interval '20 days')
        returning id into v_result;

        for r_ind in
            select pi.id as project_indicator_id, idef.code, idef.value_type,
                   idef.aggregation_method, idef.distinct_entity_type
              from kpi.project_indicator pi
              join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
             where pi.project_id = r_proj.id
               -- The "a" percentages are derived from their parent's sex
               -- disaggregation, so they carry no observations of their own.
               and idef.parent_indicator_id is null
             order by idef.code
        loop
            v_offset := v_offset + 1;

            -- ---- distinct-count indicators -------------------------------
            if r_ind.aggregation_method = 'distinct_count' then
                v_n := greatest(1, round((2 + kpi.demo_random(r_proj.code || r_period.code || r_ind.code || 'n') * 6) * v_growth)::integer);

                -- Entities are drawn from a window that overlaps between
                -- projects, so the same student or partner recurs.
                select array_agg(e.id) into v_entity_ids from (
                    select id from kpi.entity
                     where entity_type = r_ind.distinct_entity_type
                       and merged_into_id is null
                       and case when r_ind.code = 'KPI_4' then external_ref like 'INST-STU-%'
                                when r_ind.code = 'KPI_7' then external_ref like 'NARS-SCI-%'
                                when r_ind.code = 'KPI_6' then external_ref like 'ROR-DP-%'
                                when r_ind.code = 'KPI_13' then external_ref like 'ROR-ARI-%'
                                when r_ind.code = 'KPI_14' then external_ref like 'ROR-SCP-%'
                                else true end
                     order by ((id * 13 + v_offset * 7) % 97), id
                     limit v_n
                ) e;

                if v_entity_ids is null then continue; end if;

                -- KPIs 4-7 require the SEX split, so the entities are divided
                -- between two observations.
                if r_ind.code in ('KPI_4', 'KPI_5', 'KPI_6', 'KPI_7') then
                    foreach v_sex in array array['F', 'M'] loop
                        declare
                            v_slice bigint[];
                        begin
                            select array_agg(x) into v_slice from (
                                select unnest(v_entity_ids) as x offset
                                    case when v_sex = 'F' then 0 else ceil(array_length(v_entity_ids,1) * 0.45) end
                                limit case when v_sex = 'F' then ceil(array_length(v_entity_ids,1) * 0.45)
                                           else array_length(v_entity_ids,1) end
                            ) s;
                            if v_slice is null or array_length(v_slice, 1) = 0 then continue; end if;

                            insert into kpi.observation (project_indicator_id, reporting_period_id,
                                    activity_result_id, observed_on, numerator, status,
                                    country_id, commodity_id, recorded_by,
                                    validated_by, validated_at, source_system)
                            values (r_ind.project_indicator_id, r_period.id, v_result,
                                    r_period.end_date - 5, array_length(v_slice, 1), 'validated',
                                    v_country, v_commodity, 'project.officer',
                                    'melia.reviewer', r_period.end_date + interval '20 days',
                                    'project-platform')
                            returning id into v_obs;

                            insert into kpi.observation_category (observation_id, dimension_id, dimension_category_id)
                            select v_obs, d.id, c.id from kpi.dimension d
                             join kpi.dimension_category c on c.dimension_id = d.id
                             where d.code = 'SEX' and c.code = v_sex;

                            insert into kpi.observation_entity (observation_id, entity_id)
                            select v_obs, unnest(v_slice);
                        end;
                    end loop;
                else
                    insert into kpi.observation (project_indicator_id, reporting_period_id,
                            activity_result_id, observed_on, numerator, status,
                            country_id, commodity_id, recorded_by,
                            validated_by, validated_at, source_system)
                    values (r_ind.project_indicator_id, r_period.id, v_result,
                            r_period.end_date - 5, array_length(v_entity_ids, 1), 'validated',
                            v_country, v_commodity, 'project.officer',
                            'melia.reviewer', r_period.end_date + interval '20 days',
                            'project-platform')
                    returning id into v_obs;

                    insert into kpi.observation_entity (observation_id, entity_id)
                    select v_obs, unnest(v_entity_ids);
                end if;

            -- ---- ratio and percentage indicators --------------------------
            elsif r_ind.value_type in ('percentage', 'ratio') then
                if r_ind.code = 'KPI_2' then
                    -- Papers per IRS: papers over headcount.
                    v_num := round((2 + kpi.demo_random(r_proj.code || r_period.code || r_ind.code || 'p') * 8) * v_growth);
                    v_den := 6 + round(kpi.demo_random(r_proj.code || r_period.code || r_ind.code || 'irs') * 4);
                elsif r_ind.code = 'KPI_9' then
                    -- Genetic gain, weighted by trial count.
                    v_num := round((0.8 + kpi.demo_random(r_proj.code || r_period.code || r_ind.code || 'g') * 1.6) * v_growth * 100) / 100.0;
                    v_den := 100;
                elsif r_ind.code = 'KPI_10' then
                    v_num := (array[88, 92, 95, 97, 100])[1 + floor(kpi.demo_random(r_proj.code || r_period.code || r_ind.code || 'c') * 5)::int];
                    v_den := 100;
                else
                    -- Proposal inclusion shares.
                    v_den := 4 + floor(kpi.demo_random(r_proj.code || r_period.code || r_ind.code || 'd') * 12);
                    v_num := least(v_den, floor(v_den * (0.25 + kpi.demo_random(r_proj.code || r_period.code || r_ind.code || 'i') * 0.45)));
                end if;

                insert into kpi.observation (project_indicator_id, reporting_period_id,
                        activity_result_id, observed_on, numerator, denominator, weight,
                        status, country_id, commodity_id, recorded_by,
                        validated_by, validated_at, source_system)
                values (r_ind.project_indicator_id, r_period.id,
                        case when r_ind.code in ('KPI_2', 'KPI_10') then null else v_result end,
                        r_period.end_date - 5, v_num, v_den,
                        case when r_ind.code = 'KPI_9'
                             then 50 + floor(kpi.demo_random(r_proj.code || r_period.code || r_ind.code || 'w') * 250) else 1 end,
                        'validated', v_country, v_commodity, 'project.officer',
                        'melia.reviewer', r_period.end_date + interval '20 days',
                        'project-platform');

            -- ---- simple sums ---------------------------------------------
            else
                v_base := case r_ind.code
                            when 'KPI_1'  then 3 + kpi.demo_random(r_proj.code || r_period.code || r_ind.code || 'b') * 9
                            when 'KPI_3'  then     kpi.demo_random(r_proj.code || r_period.code || r_ind.code || 'b') * 2
                            when 'KPI_15' then     kpi.demo_random(r_proj.code || r_period.code || r_ind.code || 'b') * 1.6
                            when 'KPI_16' then 1 + kpi.demo_random(r_proj.code || r_period.code || r_ind.code || 'b') * 5
                            else               1 + kpi.demo_random(r_proj.code || r_period.code || r_ind.code || 'b') * 4
                          end;
                v_num := round(v_base * v_growth);
                if v_num <= 0 then v_num := 0; end if;

                insert into kpi.observation (project_indicator_id, reporting_period_id,
                        activity_result_id, observed_on, numerator, status,
                        country_id, commodity_id, recorded_by,
                        validated_by, validated_at, source_system)
                values (r_ind.project_indicator_id, r_period.id, v_result,
                        r_period.end_date - 5, v_num, 'validated',
                        v_country, v_commodity, 'project.officer',
                        'melia.reviewer', r_period.end_date + interval '20 days',
                        'project-platform');
            end if;
        end loop;
    end loop;
end loop;
end $$;

-- Evidence for the indicators that require it.
insert into kpi.evidence (observation_id, uri, evidence_type, title, uploaded_by, uploaded_at)
select o.id,
       'https://evidence.example.org/' || idef.code || '/' || o.id,
       case idef.code
           when 'KPI_1'  then 'DOI'
           when 'KPI_3'  then 'DOI'
           when 'KPI_5'  then 'thesis_record'
           when 'KPI_8'  then 'gazette'
           when 'KPI_10' then 'audit_report'
           else 'award_letter'
       end,
       idef.code || ' supporting record',
       'project.officer',
       o.observed_on + interval '3 days'
from kpi.observation o
join kpi.project_indicator pi      on pi.id = o.project_indicator_id
join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
where idef.requires_evidence
  -- One indicator is deliberately left without evidence; see the integrity
  -- section below.
  and not (idef.code = 'KPI_15');

-- =============================================================================
-- 5. Targets
--
-- 2023-2024 targets everywhere; 2025 targets only for the first three
-- categories, so the dashboard has genuine "target not supplied" cases to show
-- (framework 4.2: no targets are present in the source file).
-- =============================================================================

-- Targets are derived from each KPI's own 2023 outturn and grown 15% a year,
-- against actuals that grow about 12% — so achievement lands near, but mostly
-- below, 100% and the traffic lights show a realistic spread rather than every
-- KPI pinned to one colour.
-- The rollup views are recursive and union-based, so the 2023 baselines are
-- materialised once here rather than re-evaluated per target row.
create temporary table t_base_inst as
select t.institution_kpi_id, t.value
  from kpi.v_institution_kpi_total t
  join kpi.reporting_period b on b.id = t.reporting_period_id and b.code = 'FY2023'
 where t.value is not null and t.value > 0;
create index on t_base_inst (institution_kpi_id);

create temporary table t_base_prog as
select t.program_kpi_id, t.value
  from kpi.v_program_kpi_total t
  join kpi.reporting_period b on b.id = t.reporting_period_id and b.code = 'FY2023'
 where t.value is not null and t.value > 0;
create index on t_base_prog (program_kpi_id);

insert into kpi.institution_kpi_target (institution_kpi_id, reporting_period_id,
                                        target_value, cumulative_target, note)
select ik.id, rp.id,
       case when idef.value_type in ('percentage', 'ratio')
            then least(base.value * (1 + 0.05 * (rp.fiscal_year - 2023)),
                       case when idef.value_type = 'percentage' then 100 else 1e9 end)
            else round(base.value * (1 + 0.15 * (rp.fiscal_year - 2023)), 2)
       end,
       case when idef.value_type not in ('percentage', 'ratio')
            then round(base.value * (rp.fiscal_year - 2022) * 1.2, 2) end,
       'Illustrative target derived from the 2023 outturn — to be replaced by Program/MELIA figures.'
from kpi.institution_kpi ik
join kpi.indicator_definition idef on idef.id = ik.indicator_definition_id
join kpi.kpi_category cat on cat.id = idef.kpi_category_id
join kpi.reporting_period rp
  on rp.period_type = 'year' and rp.fiscal_year between 2023 and 2026
join t_base_inst base on base.institution_kpi_id = ik.id
where idef.parent_indicator_id is null
  -- No 2025 targets for two categories, so the dashboard has genuine
  -- "target not supplied" cases (framework 4.2: the source file has none).
  and not (rp.fiscal_year = 2025 and cat.code in ('RECOGNITION', 'SOCIETY_INCLUSION'));

insert into kpi.program_kpi_target (program_kpi_id, reporting_period_id, target_value, note)
select pk.id, rp.id,
       case when idef.value_type in ('percentage', 'ratio')
            then least(base.value * (1 + 0.05 * (rp.fiscal_year - 2023)),
                       case when idef.value_type = 'percentage' then 100 else 1e9 end)
            else round(base.value * (1 + 0.15 * (rp.fiscal_year - 2023)), 2)
       end,
       'Illustrative target derived from the 2023 outturn.'
from kpi.program_kpi pk
join kpi.indicator_definition idef on idef.id = pk.indicator_definition_id
join kpi.reporting_period rp
  on rp.period_type = 'year' and rp.fiscal_year between 2023 and 2025
join t_base_prog base on base.program_kpi_id = pk.id
where idef.parent_indicator_id is null;

-- =============================================================================
-- 6. Seeded data-quality problems — one for each of the seven dimensions
--
-- Every problem below is deliberate. They exist so the data-quality dashboard,
-- the flag workflow and the "flagged records are excluded, not deleted" rule
-- can all be demonstrated on real rows.
-- =============================================================================

-- --- Ingestion batches, so staging-layer problems have a home ---------------
insert into kpi.ingestion_batch (source_system, integration_mode, source_reference,
                                 started_at, completed_at, status, initiated_by)
values ('project-platform', 'api', 'cursor:2025-Q4-001',
        timestamptz '2025-10-05 02:00+01', timestamptz '2025-10-05 02:14+01',
        'succeeded', 'etl.service'),
       ('project-platform', 'file_etl', 'Q4_2025_results_export.xlsx',
        timestamptz '2025-10-06 02:00+01', timestamptz '2025-10-06 02:31+01',
        'succeeded', 'etl.service'),
       ('finance-system', 'file_etl', 'budget_actuals_2025.csv',
        timestamptz '2025-10-07 02:00+01', null, 'failed', 'etl.service');

-- --- 1. COMPLETENESS -------------------------------------------------------
-- KPI 2 (papers per IRS) mirrors the source file: mapped and expected, but with
-- no value reported for 2025 by three projects.
delete from kpi.observation o
using kpi.project_indicator pi, kpi.indicator_definition idef,
      kpi.reporting_period rp, kpi.project prj
where o.project_indicator_id = pi.id
  and pi.indicator_definition_id = idef.id
  and o.reporting_period_id = rp.id
  and pi.project_id = prj.id
  and idef.code = 'KPI_2'
  and rp.fiscal_year = 2025
  and prj.code in ('PRJ-CAS-02', 'PRJ-LEG-02', 'PRJ-BAN-02');

insert into kpi.dq_flag (dq_rule_id, staging_record_id, observation_id, severity, detail, detected_by)
select r.id, null, o.id, 'warning',
       'Country not coded on submission; geography defaulted from the project.',
       'validation.job'
from kpi.dq_rule r
join lateral (
    select o.id from kpi.observation o
     join kpi.reporting_period rp on rp.id = o.reporting_period_id
     where rp.fiscal_year = 2025
     order by o.id limit 14
) o on true
where r.code = 'GEO_CODED';

-- Institutional KPIs with no 2025 target at all (Recognition, Inclusion).
insert into kpi.dq_flag (dq_rule_id, observation_id, severity, detail, detected_by)
select r.id, o.id, 'warning',
       'No 2025 target supplied for this KPI; traffic-light reporting is unavailable.',
       'validation.job'
from kpi.dq_rule r
cross join lateral (
    select o.id
      from kpi.observation o
      join kpi.project_indicator pi on pi.id = o.project_indicator_id
      join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
      join kpi.kpi_category cat on cat.id = idef.kpi_category_id
      join kpi.reporting_period rp on rp.id = o.reporting_period_id
     where cat.code in ('RECOGNITION', 'SOCIETY_INCLUSION')
       and rp.fiscal_year = 2025
     order by o.id limit 9
) o
where r.code = 'NO_TARGET';

-- --- 2. ACCURACY -----------------------------------------------------------
-- Four observations inflated far beyond the indicator's history, as a
-- mistyped-value would be. Blocking, so they are excluded until reviewed.
with inflated as (
    update kpi.observation o
       set numerator = o.numerator * 40,
           source_note = 'Suspected data-entry error: value inflated on submission.'
      from kpi.project_indicator pi, kpi.indicator_definition idef, kpi.reporting_period rp
     where o.project_indicator_id = pi.id
       and pi.indicator_definition_id = idef.id
       and o.reporting_period_id = rp.id
       and idef.code in ('KPI_1', 'KPI_16')
       and rp.code in ('2024-Q3', '2025-Q2')
       and o.id in (
            select o2.id from kpi.observation o2
             join kpi.project_indicator pi2 on pi2.id = o2.project_indicator_id
             join kpi.indicator_definition i2 on i2.id = pi2.indicator_definition_id
             join kpi.reporting_period rp2 on rp2.id = o2.reporting_period_id
            where i2.code in ('KPI_1', 'KPI_16') and rp2.code in ('2024-Q3', '2025-Q2')
            order by o2.id limit 4)
    returning o.id
)
insert into kpi.dq_flag (dq_rule_id, observation_id, severity, detail, detected_by)
select r.id, i.id, 'error',
       'Value is more than 10 standard deviations above the indicator mean for this project.',
       'validation.job'
from inflated i, kpi.dq_rule r where r.code = 'OUTLIER_VALUE';

-- A unit mismatch: a genetic-gain figure reported as a fraction rather than a
-- percentage. Warning only, so it still publishes but is visible.
insert into kpi.dq_flag (dq_rule_id, observation_id, severity, detail, detected_by)
select r.id, o.id, 'warning',
       'Value magnitude suggests a fraction (0-1) where the definition expects a percentage.',
       'validation.job'
from kpi.dq_rule r
cross join lateral (
    select o.id from kpi.observation o
      join kpi.project_indicator pi on pi.id = o.project_indicator_id
      join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
     where idef.code = 'KPI_9' order by o.id limit 3
) o
where r.code = 'UNIT_MISMATCH';

-- --- 3. CONSISTENCY --------------------------------------------------------
-- The same person reported as female by one project and male by another.
insert into kpi.dq_flag (dq_rule_id, entity_id, severity, detail, detected_by)
select r.id, e.id, 'warning',
       'Entity appears under conflicting SEX categories in different project submissions.',
       'validation.job'
from kpi.dq_rule r
cross join lateral (
    select e.id
      from kpi.entity e
      join kpi.observation_entity oe on oe.entity_id = e.id
      join kpi.observation o on o.id = oe.observation_id
     where e.entity_type = 'person'
     group by e.id
    having count(distinct o.disaggregation_key) > 1
     order by e.id limit 7
) e
where r.code = 'SEX_CONFLICT';

-- --- 4. TIMELINESS ---------------------------------------------------------
-- Late submissions: results filed months after the period closed.
with late as (
    update kpi.observation o
       set validated_at = rp.end_date + interval '240 days',
           source_note = 'Backfilled during the annual reporting catch-up.'
      from kpi.reporting_period rp
     where rp.id = o.reporting_period_id
       and rp.code in ('2023-Q2', '2024-Q1')
       and o.id in (select o2.id from kpi.observation o2
                     join kpi.reporting_period r2 on r2.id = o2.reporting_period_id
                    where r2.code in ('2023-Q2', '2024-Q1') order by o2.id limit 12)
    returning o.id
)
insert into kpi.dq_flag (dq_rule_id, observation_id, severity, detail, detected_by)
select r.id, l.id, 'warning',
       'Validated more than 200 days after the reporting period closed.',
       'validation.job'
from late l, kpi.dq_rule r where r.code = 'LATE_SUBMISSION';

-- Stale: one project stopped reporting two indicators after 2023.
delete from kpi.observation o
using kpi.project_indicator pi, kpi.indicator_definition idef,
      kpi.reporting_period rp, kpi.project prj
where o.project_indicator_id = pi.id
  and pi.indicator_definition_id = idef.id
  and pi.project_id = prj.id
  and o.reporting_period_id = rp.id
  and prj.code = 'PRJ-NRM-03'
  and idef.code in ('KPI_16', 'KPI_15')
  and rp.fiscal_year > 2023;

insert into kpi.dq_flag (dq_rule_id, observation_id, severity, detail, detected_by)
select r.id, o.id, 'warning',
       'No submission for this indicator since 2023; the reporting cycle expects quarterly data.',
       'validation.job'
from kpi.dq_rule r
cross join lateral (
    select o.id from kpi.observation o
      join kpi.project_indicator pi on pi.id = o.project_indicator_id
      join kpi.project prj on prj.id = pi.project_id
      join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
     where prj.code = 'PRJ-NRM-03' and idef.code in ('KPI_15', 'KPI_16')
     order by o.id desc limit 2
) o
where r.code = 'STALE_DATA';

-- --- 5. VALIDITY -----------------------------------------------------------
-- Invalid values never become observations: the schema rejects them, so they
-- stay in staging with a flag. This is what the architecture's validation layer
-- looks like in practice.
insert into kpi.staging_record (ingestion_batch_id, source_entity, source_record_ref,
                                payload, process_status, error_text)
select b.id, 'indicator_value', 'SRC-' || lpad(n::text, 5, '0'),
       jsonb_build_object(
           'project_code', (array['PRJ-CAS-01','PRJ-LEG-02','PRJ-BAN-01','PRJ-NRM-01'])[1 + (n % 4)],
           'kpi_code',     (array['KPI_18','KPI_10','KPI_1','KPI_6'])[1 + (n % 4)],
           'period',       '2025-Q3',
           'value',        (array['142','-8','103.5','-3'])[1 + (n % 4)],
           'country',      (array['Nigeria','NG','Zambya','Uganda'])[1 + (n % 4)]),
       'flagged',
       (array['Percentage above 100.',
              'Negative value for a count-type indicator.',
              'Percentage above 100.',
              'Negative value for a count-type indicator.'])[1 + (n % 4)]
from generate_series(1, 12) as n
join kpi.ingestion_batch b on b.source_reference = 'cursor:2025-Q4-001';

insert into kpi.dq_flag (dq_rule_id, staging_record_id, severity, detail, detected_by)
select case when s.payload ->> 'value' like '-%' then r_neg.id else r_pct.id end,
       s.id, 'error', s.error_text, 'validation.job'
from kpi.staging_record s
cross join (select id from kpi.dq_rule where code = 'NEGATIVE_COUNT') r_neg
cross join (select id from kpi.dq_rule where code = 'PCT_RANGE') r_pct
where s.process_status = 'flagged';

-- Free-text geography that did not resolve to an ISO code.
insert into kpi.staging_record (ingestion_batch_id, source_entity, source_record_ref,
                                payload, process_status, error_text)
select b.id, 'activity', 'SRC-GEO-' || n,
       jsonb_build_object('project_code', 'PRJ-NRM-02', 'location',
                          (array['Sahel region','northern zone','Kano state (approx)'])[1 + (n % 3)]),
       'flagged', 'Location does not resolve to an ISO 3166 code.'
from generate_series(1, 6) as n
join kpi.ingestion_batch b on b.source_reference = 'Q4_2025_results_export.xlsx';

insert into kpi.dq_flag (dq_rule_id, staging_record_id, severity, detail, detected_by)
select r.id, s.id, 'warning', s.error_text, 'validation.job'
from kpi.staging_record s, kpi.dq_rule r
where s.source_record_ref like 'SRC-GEO-%' and r.code = 'GEO_CODED';

-- --- 6. UNIQUENESS ---------------------------------------------------------
-- Duplicate partner records under slightly different names. Three are already
-- merged; six await a decision. Distinct counts follow the merges.
insert into kpi.entity (entity_type, display_name, external_ref, external_ref_system)
select 'organization',
       p.name || ' (Ltd)',
       'ROR-DUP-' || lpad(n::text, 3, '0'), 'ROR'
from generate_series(1, 9) as n
join lateral (
    select name from kpi.partner where partner_type = 'NARS'
     order by code limit 1 offset (n - 1)
) p on true;

-- Merge the first three into their originals.
update kpi.entity dup
   set merged_into_id = orig.id, merged_at = timestamptz '2025-09-01 10:00+01',
       merged_by = 'melia.datasteward'
  from kpi.entity orig
 where dup.external_ref in ('ROR-DUP-001', 'ROR-DUP-002', 'ROR-DUP-003')
   and orig.display_name = replace(dup.display_name, ' (Ltd)', '')
   and orig.entity_type = 'organization';

-- The remaining six are raised as candidates for review.
insert into kpi.entity_duplicate_candidate (entity_id, duplicate_of_id, match_score,
                                            match_method, status)
select dup.id, orig.id, 0.93, 'canonical_key', 'open'
from kpi.entity dup
join kpi.entity orig on orig.display_name = replace(dup.display_name, ' (Ltd)', '')
                    and orig.entity_type = 'organization'
where dup.external_ref like 'ROR-DUP-%'
  and dup.merged_into_id is null;

insert into kpi.dq_flag (dq_rule_id, entity_id, severity, detail, detected_by)
select r.id, c.entity_id, 'warning',
       'Possible duplicate organisation detected before distinct-count aggregation.',
       'validation.job'
from kpi.entity_duplicate_candidate c, kpi.dq_rule r
where c.status = 'open' and r.code = 'DUPLICATE_ENTITY';

-- The merged duplicates are also reported by a project, so the deduplication
-- has visible effect on KPI 6.
--
-- One transaction, because the observation's entity list and its numerator must
-- agree by the time the deferred contract trigger fires at commit.
begin;

insert into kpi.observation_entity (observation_id, entity_id)
select o.id, e.id
from kpi.entity e
cross join lateral (
    select o.id
      from kpi.observation o
      join kpi.project_indicator pi on pi.id = o.project_indicator_id
      join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
      join kpi.project prj on prj.id = pi.project_id
     where idef.code = 'KPI_6' and prj.code = 'PRJ-SOC-01'
       and o.disaggregation_key = 'SEX=F'
     order by o.id limit 1
) o
where e.external_ref in ('ROR-DUP-001', 'ROR-DUP-002', 'ROR-DUP-003')
on conflict do nothing;

-- The numerator must be restated to match the entities now listed.
update kpi.observation o
   set numerator = sub.n
  from (select oe.observation_id, count(distinct coalesce(e.merged_into_id, e.id)) as n
          from kpi.observation_entity oe
          join kpi.entity e on e.id = oe.entity_id
         group by oe.observation_id) sub
 where sub.observation_id = o.id and o.numerator is distinct from sub.n;

commit;

-- --- 7. INTEGRITY ----------------------------------------------------------
-- Records referring to things that do not exist. These never reach the KPI
-- layer; they sit in staging as an unresolved integrity problem.
insert into kpi.staging_record (ingestion_batch_id, source_entity, source_record_ref,
                                payload, process_status, error_text)
select b.id, 'activity_result', 'SRC-ORPH-' || n,
       jsonb_build_object('project_code', 'PRJ-XXX-9' || n,
                          'kpi_code', 'KPI_' || (30 + n),
                          'period', '2025-Q4', 'value', 12),
       'rejected', 'Project code and KPI code do not exist in the reference data.'
from generate_series(1, 5) as n
join kpi.ingestion_batch b on b.source_reference = 'cursor:2025-Q4-001';

insert into kpi.dq_flag (dq_rule_id, staging_record_id, severity, detail, detected_by)
select r.id, s.id, 'error', s.error_text, 'validation.job'
from kpi.staging_record s, kpi.dq_rule r
where s.source_record_ref like 'SRC-ORPH-%' and r.code = 'ORPHAN_REFERENCE';

-- A mapping retired mid-2025: the project keeps reporting, but its figures stop
-- reaching the program KPI from that date. Historical periods are unaffected,
-- which is the point of versioned mappings.
update kpi.project_indicator_contribution c
   set mapping_status = 'retired', effective_to = date '2025-06-30',
       note = 'Retired: indicator moved to the Legume program under the 2025 realignment.'
  from kpi.project_indicator pi, kpi.project prj, kpi.indicator_definition idef
 where c.project_indicator_id = pi.id
   and pi.project_id = prj.id
   and pi.indicator_definition_id = idef.id
   and prj.code = 'PRJ-LEG-03'
   and idef.code in ('KPI_6', 'KPI_16');

-- KPI 15 requires evidence but none was attached (see section 4).
insert into kpi.dq_flag (dq_rule_id, observation_id, severity, detail, detected_by)
select r.id, o.id, 'error',
       'Indicator requires supporting evidence; no award letter attached.',
       'validation.job'
from kpi.dq_rule r
cross join lateral (
    select o.id from kpi.observation o
      join kpi.project_indicator pi on pi.id = o.project_indicator_id
      join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
      join kpi.reporting_period rp on rp.id = o.reporting_period_id
     where idef.code = 'KPI_15' and rp.fiscal_year = 2025
     order by o.id limit 6
) o
where r.code = 'EVIDENCE_MISSING';

-- Some flags have already been worked through, so the dashboard shows a
-- realistic mix of open, under review and resolved.
update kpi.dq_flag set status = 'under_review'
 where id in (select id from kpi.dq_flag where status = 'open' order by id limit 8 offset 3);

update kpi.dq_flag
   set status = 'resolved', resolved_at = timestamptz '2025-11-10 14:00+01',
       resolved_by = 'melia.reviewer',
       resolution_note = 'Corrected at source and re-imported.'
 where id in (select id from kpi.dq_flag where status = 'open' order by id limit 11 offset 20);

-- =============================================================================
-- 7. Users, snapshots, and period close
-- =============================================================================

insert into kpi.app_user (username, email, full_name)
values ('a.adeyemi',      'a.adeyemi@example.org',      'Dr A. Adeyemi'),
       ('melia.lead',     'melia.lead@example.org',     'MELIA Team Lead'),
       ('melia.reviewer', 'melia.reviewer@example.org', 'MELIA Data Reviewer'),
       ('m.okafor',       'm.okafor@example.org',       'M. Okafor'),
       ('dg.office',      'dg.office@example.org',      'Director General Office');

insert into kpi.app_user_role (app_user_id, app_role_id)
select u.id, r.id
from kpi.app_user u
join (values ('a.adeyemi','PROGRAM_LEADER'), ('melia.lead','MELIA'),
             ('melia.reviewer','MELIA'), ('m.okafor','PROJECT_MANAGER'),
             ('dg.office','EXEC')) as v(username, role_code) on v.username = u.username
join kpi.app_role r on r.code = v.role_code;

insert into kpi.app_user_scope (app_user_id, institution_id, program_id, project_id)
select u.id,
       case when v.scope = 'institution' then (select id from kpi.institution) end,
       case when v.scope = 'program' then (select id from kpi.program where code = 'PRG-CASSAVA') end,
       case when v.scope = 'project' then (select id from kpi.project where code = 'PRJ-CAS-01') end
from kpi.app_user u
join (values ('dg.office','institution'), ('melia.lead','institution'),
             ('a.adeyemi','program'), ('m.okafor','project')) as v(username, scope)
  on v.username = u.username;

-- Freeze each closed year, then lock it for data entry.
select kpi.take_snapshot(rp.id, 'melia.lead', 'validated',
                         'Annual results freeze for ' || rp.code)
from kpi.reporting_period rp
where rp.period_type = 'year' and rp.fiscal_year between 2023 and 2025
order by rp.fiscal_year;

update kpi.reporting_period set is_open = false where fiscal_year < 2025;
update kpi.reporting_period set is_open = false
 where period_type = 'quarter' and fiscal_year = 2025 and start_date < date '2025-10-01';

drop table if exists t_program_kpi;
drop table if exists t_base_inst;
drop table if exists t_base_prog;

-- =============================================================================
-- Load summary
-- =============================================================================

do $$
declare
    v_obs bigint; v_ent bigint; v_flags bigint; v_dims bigint; v_snap bigint;
begin
    select count(*) into v_obs   from kpi.observation;
    select count(*) into v_ent   from kpi.entity;
    select count(*) into v_flags from kpi.dq_flag;
    select count(distinct r.dimension) into v_dims
      from kpi.dq_flag f join kpi.dq_rule r on r.id = f.dq_rule_id;
    select count(*) into v_snap  from kpi.kpi_snapshot;

    raise notice 'demo data loaded: % observations, % entities, % DQ flags across % of 7 quality dimensions, % snapshot rows',
        v_obs, v_ent, v_flags, v_dims, v_snap;

    if v_dims < 7 then
        raise exception 'demo data does not cover all seven data-quality dimensions (got %)', v_dims;
    end if;
end $$;
