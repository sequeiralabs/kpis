-- =============================================================================
-- 03_results.sql — activities, activity results, the countable-entity registry,
--                  observations, disaggregation bridge, integrity triggers
--
-- Implements steps 1-4 of the framework's result chain (section 6):
--   1. Activity implemented by a Project
--   2. Activity Output / Result recorded
--   3. Result mapped to a Project Indicator
--   4. Project Indicator validated (data quality checks)
-- =============================================================================

set search_path = kpi, public;

-- -----------------------------------------------------------------------------
-- Step 1 — Activities
-- -----------------------------------------------------------------------------

create table kpi.activity (
    id              bigint generated always as identity primary key,
    project_id      bigint not null references kpi.project (id) on delete cascade,
    work_package_id bigint references kpi.work_package (id) on delete set null,
    code            text   not null,
    name            text   not null,
    description     text,
    country_id      bigint references kpi.country (id) on delete set null,
    location_id     bigint references kpi.location (id) on delete set null,
    commodity_id    bigint references kpi.commodity (id) on delete set null,
    planned_start   date,
    planned_end     date,
    actual_start    date,
    actual_end      date,
    status          kpi.lifecycle_status not null default 'planned',
    responsible     text,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    constraint activity_code_uq unique (project_id, code),
    constraint activity_planned_dates_ck check (planned_end is null or planned_start is null
                                                or planned_end >= planned_start),
    constraint activity_actual_dates_ck  check (actual_end is null or actual_start is null
                                                or actual_end >= actual_start)
);
create index activity_project_idx   on kpi.activity (project_id);
create index activity_country_idx   on kpi.activity (country_id);
create index activity_commodity_idx on kpi.activity (commodity_id);
create trigger activity_touch before update on kpi.activity
    for each row execute function kpi.set_updated_at();

create table kpi.activity_partner (
    activity_id bigint not null references kpi.activity (id) on delete cascade,
    partner_id  bigint not null references kpi.partner (id) on delete restrict,
    role        text,
    primary key (activity_id, partner_id)
);

-- Framework 13.1: activity dates must fall inside the implementing project's
-- start/end dates, and the project must be active.
create or replace function kpi.tg_activity_within_project()
returns trigger
language plpgsql
as $$
declare
    v_start date;
    v_end   date;
    v_status kpi.lifecycle_status;
begin
    select p.start_date, p.end_date, p.status
      into v_start, v_end, v_status
      from kpi.project p where p.id = new.project_id;

    if v_status in ('cancelled', 'planned') then
        raise exception 'project % is % and cannot receive activities', new.project_id, v_status
            using errcode = 'integrity_constraint_violation';
    end if;

    if v_start is not null and new.actual_start is not null and new.actual_start < v_start then
        raise exception 'activity starts % before its project start %', new.actual_start, v_start
            using errcode = 'integrity_constraint_violation';
    end if;

    if v_end is not null and new.actual_end is not null and new.actual_end > v_end then
        raise exception 'activity ends % after its project end %', new.actual_end, v_end
            using errcode = 'integrity_constraint_violation';
    end if;

    return new;
end;
$$;

create trigger activity_within_project_ck before insert or update on kpi.activity
    for each row execute function kpi.tg_activity_within_project();

-- -----------------------------------------------------------------------------
-- Step 2 — Activity results
--
-- The narrative/evidence envelope for one activity in one reporting period.
-- The numbers live in `observation` so a single reported result can feed several
-- indicators and several disaggregation slices.
-- -----------------------------------------------------------------------------

create table kpi.activity_result (
    id                  bigint generated always as identity primary key,
    activity_id         bigint not null references kpi.activity (id) on delete cascade,
    reporting_period_id bigint not null references kpi.reporting_period (id) on delete restrict,
    result_date         date   not null,
    title               text,
    narrative           text,
    status              kpi.approval_status not null default 'draft',
    recorded_by         text,
    recorded_at         timestamptz not null default now(),
    validated_by        text,
    validated_at        timestamptz,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),
    constraint activity_result_validated_ck check (
        (status in ('validated', 'rejected')) = (validated_at is not null)
    )
);
create index activity_result_activity_idx on kpi.activity_result (activity_id);
create index activity_result_period_idx   on kpi.activity_result (reporting_period_id, status);
create trigger activity_result_touch before update on kpi.activity_result
    for each row execute function kpi.set_updated_at();

create table kpi.evidence (
    id                 bigint generated always as identity primary key,
    activity_result_id bigint references kpi.activity_result (id) on delete cascade,
    observation_id     bigint,   -- FK added after observation is created
    uri                text not null,      -- object-store key, URL, DOI
    evidence_type      text,               -- 'DOI', 'thesis_record', 'gazette', 'attendance_sheet'
    media_type         text,
    title              text,
    description        text,
    uploaded_by        text,
    uploaded_at        timestamptz not null default now(),
    constraint evidence_owner_ck check (
        num_nonnulls(activity_result_id, observation_id) >= 1
    )
);
create index evidence_result_idx on kpi.evidence (activity_result_id);

-- -----------------------------------------------------------------------------
-- The countable-entity registry (framework 6.2, 11.1)
--
-- Eight of the twenty KPIs aggregate by COUNT(DISTINCT entity_id) because the
-- same student, delivery partner, ARI or innovation may be reported by several
-- projects. Summing project-level counts would double-count them. Every such
-- observation therefore names the individual things it counted, and the rollups
-- in 04 count distinct entities directly at each level rather than adding up
-- the level below.
--
-- merged_into_id supports deduplication: when two records turn out to be the
-- same real-world entity, the loser points at the winner and every distinct
-- count follows the pointer. Records are merged, never deleted, so the audit
-- trail survives.
-- -----------------------------------------------------------------------------

create table kpi.entity (
    id             bigint generated always as identity primary key,
    entity_type    kpi.entity_type not null,
    display_name   text not null,
    -- Authoritative external identifier where one exists: ORCID, DOI, ROR,
    -- variety gazette number, student registration number.
    external_ref   text,
    external_ref_system text,
    -- Normalised name used for fuzzy duplicate detection before a distinct
    -- count is run (framework 13.1).
    canonical_key  text generated always as (lower(regexp_replace(display_name, '[^a-zA-Z0-9]+', '', 'g'))) stored,
    country_id     bigint references kpi.country (id) on delete set null,
    partner_id     bigint references kpi.partner (id) on delete set null,
    -- Beneficiary/partner records may hold personal data; drives masking in the
    -- dashboard's role-based access rules (framework 7.2, 18).
    is_personal_data boolean not null default false,
    merged_into_id bigint references kpi.entity (id) on delete restrict,
    merged_at      timestamptz,
    merged_by      text,
    attributes     jsonb not null default '{}'::jsonb,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now(),
    constraint entity_self_merge_ck check (merged_into_id is distinct from id),
    constraint entity_merge_stamp_ck check ((merged_into_id is not null) = (merged_at is not null))
);
create unique index entity_external_ref_uq
    on kpi.entity (entity_type, external_ref_system, external_ref)
    where external_ref is not null;
create index entity_canonical_idx on kpi.entity (entity_type, canonical_key);
create index entity_merged_idx    on kpi.entity (merged_into_id);
create trigger entity_touch before update on kpi.entity
    for each row execute function kpi.set_updated_at();

-- Merge chains would make distinct counts depend on traversal order.
create or replace function kpi.tg_entity_no_merge_chain()
returns trigger
language plpgsql
as $$
begin
    if new.merged_into_id is not null then
        if exists (select 1 from kpi.entity e
                    where e.id = new.merged_into_id and e.merged_into_id is not null) then
            raise exception 'entity % is itself merged; point at the surviving record instead',
                new.merged_into_id using errcode = 'integrity_constraint_violation';
        end if;
        if exists (select 1 from kpi.entity e where e.merged_into_id = new.id) then
            raise exception 'entity % is a merge target and cannot itself be merged', new.id
                using errcode = 'integrity_constraint_violation';
        end if;
    end if;
    return new;
end;
$$;

create trigger entity_no_merge_chain_ck before insert or update on kpi.entity
    for each row execute function kpi.tg_entity_no_merge_chain();

-- Resolves an entity to its surviving record.
create or replace function kpi.canonical_entity_id(p_entity_id bigint, p_merged_into_id bigint)
returns bigint
language sql
immutable
as $$
    select coalesce(p_merged_into_id, p_entity_id);
$$;

-- -----------------------------------------------------------------------------
-- Step 3 — Observations: a result mapped to a project indicator
--
-- One row per (indicator, period, disaggregation slice, source). This is the
-- single grain every rollup in 04 reads from.
--
--   activity_result_id null -> direct entry, survey or platform import
--   denominator        populated only for ratio/percentage indicators, so that
--                      ratios recombine correctly at each level: sum the parts,
--                      then divide — never average the ratios (framework 6.2)
-- -----------------------------------------------------------------------------

create table kpi.observation (
    id                   bigint generated always as identity primary key,
    project_indicator_id bigint not null references kpi.project_indicator (id) on delete cascade,
    reporting_period_id  bigint not null references kpi.reporting_period (id) on delete restrict,
    activity_result_id   bigint references kpi.activity_result (id) on delete cascade,
    observed_on          date   not null,

    numerator            numeric(20, 6) not null,
    denominator          numeric(20, 6),
    -- Applied when the raw result is recorded in another unit, or when only part
    -- of the result counts toward this indicator.
    conversion_factor    numeric(18, 6) not null default 1,
    -- Weight for weighted_average indicators (KPI 9: trial/plot count or area).
    weight               numeric(18, 6) not null default 1,

    -- Context for drill-down and slicing (framework 9.2). Defaults are inherited
    -- from the activity when the observation comes from one.
    country_id           bigint references kpi.country (id) on delete set null,
    location_id          bigint references kpi.location (id) on delete set null,
    commodity_id         bigint references kpi.commodity (id) on delete set null,
    partner_id           bigint references kpi.partner (id) on delete set null,

    -- Denormalised fingerprint of observation_category, maintained by trigger.
    -- '' = no disaggregation. Lets every rollup group by a single column.
    disaggregation_key   text not null default '',

    status               kpi.approval_status not null default 'draft',
    source_system        text,
    source_record_ref    text,          -- key in the originating platform
    source_note          text,
    recorded_by          text,
    validated_by         text,
    validated_at         timestamptz,
    created_at           timestamptz not null default now(),
    updated_at           timestamptz not null default now(),

    constraint observation_denominator_ck check (denominator is null or denominator >= 0),
    constraint observation_factor_ck      check (conversion_factor > 0),
    constraint observation_weight_ck      check (weight >= 0),
    constraint observation_validated_ck   check (
        (status in ('validated', 'rejected')) = (validated_at is not null)
    )
);
create index observation_indicator_period_idx
    on kpi.observation (project_indicator_id, reporting_period_id, status);
create index observation_result_idx    on kpi.observation (activity_result_id);
create index observation_key_idx       on kpi.observation (disaggregation_key);
create index observation_country_idx   on kpi.observation (country_id);
create index observation_commodity_idx on kpi.observation (commodity_id);

-- A direct-entry observation is unique per indicator/period/slice.
create unique index observation_direct_uq
    on kpi.observation (project_indicator_id, reporting_period_id, disaggregation_key)
    where activity_result_id is null;

-- An activity-derived observation is unique per result/indicator/slice.
create unique index observation_from_result_uq
    on kpi.observation (activity_result_id, project_indicator_id, disaggregation_key)
    where activity_result_id is not null;

create trigger observation_touch before update on kpi.observation
    for each row execute function kpi.set_updated_at();

alter table kpi.evidence
    add constraint evidence_observation_fk
    foreign key (observation_id) references kpi.observation (id) on delete cascade;
create index evidence_observation_idx on kpi.evidence (observation_id);

-- The disaggregation slice: one row per axis.
create table kpi.observation_category (
    observation_id        bigint not null references kpi.observation (id) on delete cascade,
    dimension_id          bigint not null references kpi.dimension (id) on delete restrict,
    dimension_category_id bigint not null,
    primary key (observation_id, dimension_id),
    -- Composite FK proves the category belongs to that dimension.
    constraint observation_category_belongs_fk
        foreign key (dimension_category_id, dimension_id)
        references kpi.dimension_category (id, dimension_id) on delete restrict
);
create index observation_category_cat_idx on kpi.observation_category (dimension_category_id);

-- The individual things an observation counted, for distinct_count indicators.
create table kpi.observation_entity (
    observation_id bigint not null references kpi.observation (id) on delete cascade,
    entity_id      bigint not null references kpi.entity (id) on delete restrict,
    note           text,
    primary key (observation_id, entity_id)
);
create index observation_entity_entity_idx on kpi.observation_entity (entity_id);

comment on table kpi.observation_entity is
    'Names the entities behind a count so program and institutional rollups can COUNT(DISTINCT) instead of summing project totals.';

-- -----------------------------------------------------------------------------
-- Trigger: keep observation.disaggregation_key in sync with its categories
-- -----------------------------------------------------------------------------

create or replace function kpi.refresh_disaggregation_key()
returns trigger
language plpgsql
as $$
declare
    v_observation_id bigint := coalesce(new.observation_id, old.observation_id);
    v_key            text;
begin
    select coalesce(string_agg(d.code || '=' || c.code, '|' order by d.code, c.code), '')
      into v_key
      from kpi.observation_category oc
      join kpi.dimension d          on d.id = oc.dimension_id
      join kpi.dimension_category c on c.id = oc.dimension_category_id
     where oc.observation_id = v_observation_id;

    update kpi.observation
       set disaggregation_key = v_key
     where id = v_observation_id
       and disaggregation_key is distinct from v_key;

    return null;
end;
$$;

create trigger observation_category_key_sync
    after insert or update or delete on kpi.observation_category
    for each row execute function kpi.refresh_disaggregation_key();

-- -----------------------------------------------------------------------------
-- Trigger: inherit context from the activity when not stated explicitly
-- -----------------------------------------------------------------------------

create or replace function kpi.tg_observation_inherit_context()
returns trigger
language plpgsql
as $$
declare
    v_country bigint; v_location bigint; v_commodity bigint;
begin
    if new.activity_result_id is not null
       and (new.country_id is null or new.location_id is null or new.commodity_id is null) then
        select a.country_id, a.location_id, a.commodity_id
          into v_country, v_location, v_commodity
          from kpi.activity_result ar
          join kpi.activity a on a.id = ar.activity_id
         where ar.id = new.activity_result_id;

        new.country_id   := coalesce(new.country_id,   v_country);
        new.location_id  := coalesce(new.location_id,  v_location);
        new.commodity_id := coalesce(new.commodity_id, v_commodity);
    end if;
    return new;
end;
$$;

create trigger observation_inherit_context before insert or update on kpi.observation
    for each row execute function kpi.tg_observation_inherit_context();

-- -----------------------------------------------------------------------------
-- Deferred integrity: an observation must satisfy its indicator's contract
--
--   * every required disaggregation dimension present
--   * no category from a dimension the indicator does not declare
--   * denominator present exactly when the indicator is a ratio/percentage
--   * a percentage's numerator cannot exceed its denominator (framework 13.1)
--   * count-type indicators cannot go negative (framework 13.1)
--   * distinct_count indicators must name their entities, and the entity count
--     must match the reported numerator
--
-- Deferred so an observation and its child rows can be inserted in any order
-- within a transaction.
-- -----------------------------------------------------------------------------

create or replace function kpi.assert_observation_valid(p_observation_id bigint)
returns void
language plpgsql
as $$
declare
    v_definition_id bigint;
    v_value_type    kpi.value_type;
    v_method        kpi.aggregation_method;
    v_entity_type   kpi.entity_type;
    v_numerator     numeric;
    v_denominator   numeric;
    v_missing       text;
    v_extra         text;
    v_entity_count  bigint;
    v_bad_entities  bigint;
begin
    select pi.indicator_definition_id, idef.value_type, idef.aggregation_method,
           idef.distinct_entity_type, o.numerator, o.denominator
      into v_definition_id, v_value_type, v_method, v_entity_type, v_numerator, v_denominator
      from kpi.observation o
      join kpi.project_indicator pi      on pi.id = o.project_indicator_id
      join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
     where o.id = p_observation_id;

    if v_definition_id is null then
        return;   -- observation was deleted later in the transaction
    end if;

    -- Required dimensions present
    select string_agg(d.code, ', ' order by d.code)
      into v_missing
      from kpi.indicator_dimension idm
      join kpi.dimension d on d.id = idm.dimension_id
     where idm.indicator_definition_id = v_definition_id
       and idm.is_required
       and not exists (select 1 from kpi.observation_category oc
                        where oc.observation_id = p_observation_id
                          and oc.dimension_id = idm.dimension_id);

    if v_missing is not null then
        raise exception 'observation %: missing required disaggregation dimension(s): %',
            p_observation_id, v_missing using errcode = 'integrity_constraint_violation';
    end if;

    -- No undeclared dimensions
    select string_agg(d.code, ', ' order by d.code)
      into v_extra
      from kpi.observation_category oc
      join kpi.dimension d on d.id = oc.dimension_id
     where oc.observation_id = p_observation_id
       and not exists (select 1 from kpi.indicator_dimension idm
                        where idm.indicator_definition_id = v_definition_id
                          and idm.dimension_id = oc.dimension_id);

    if v_extra is not null then
        raise exception 'observation %: dimension(s) % are not declared for this indicator',
            p_observation_id, v_extra using errcode = 'integrity_constraint_violation';
    end if;

    -- Numerator/denominator shape
    if (v_value_type in ('percentage', 'ratio')) and v_denominator is null then
        raise exception 'observation %: indicator is a %, so denominator is required',
            p_observation_id, v_value_type using errcode = 'integrity_constraint_violation';
    end if;

    if (v_value_type not in ('percentage', 'ratio')) and v_denominator is not null then
        raise exception 'observation %: indicator is a %, so denominator must be null',
            p_observation_id, v_value_type using errcode = 'integrity_constraint_violation';
    end if;

    if v_value_type = 'percentage' and v_denominator is not null
       and v_numerator > v_denominator then
        raise exception 'observation %: percentage numerator % exceeds denominator %',
            p_observation_id, v_numerator, v_denominator
            using errcode = 'integrity_constraint_violation';
    end if;

    if v_value_type = 'count' and v_numerator < 0 then
        raise exception 'observation %: count-type indicator cannot be negative (%)',
            p_observation_id, v_numerator using errcode = 'integrity_constraint_violation';
    end if;

    -- distinct_count indicators must enumerate their entities
    if v_method = 'distinct_count' then
        select count(*) into v_entity_count
          from kpi.observation_entity oe where oe.observation_id = p_observation_id;

        if v_entity_count = 0 then
            raise exception
                'observation %: distinct_count indicator must list the % entities it counted',
                p_observation_id, v_entity_type
                using errcode = 'integrity_constraint_violation';
        end if;

        select count(*) into v_bad_entities
          from kpi.observation_entity oe
          join kpi.entity e on e.id = oe.entity_id
         where oe.observation_id = p_observation_id
           and e.entity_type <> v_entity_type;

        if v_bad_entities > 0 then
            raise exception 'observation %: % linked entities are not of type %',
                p_observation_id, v_bad_entities, v_entity_type
                using errcode = 'integrity_constraint_violation';
        end if;

        -- The stated numerator must match the entities actually listed, after
        -- resolving merges.
        select count(distinct coalesce(e.merged_into_id, e.id)) into v_entity_count
          from kpi.observation_entity oe
          join kpi.entity e on e.id = oe.entity_id
         where oe.observation_id = p_observation_id;

        if v_numerator <> v_entity_count then
            raise exception
                'observation %: numerator % does not match % distinct entities listed',
                p_observation_id, v_numerator, v_entity_count
                using errcode = 'integrity_constraint_violation';
        end if;
    end if;
end;
$$;

create or replace function kpi.tg_assert_observation_valid()
returns trigger
language plpgsql
as $$
begin
    perform kpi.assert_observation_valid(new.id);
    return null;
end;
$$;

create or replace function kpi.tg_assert_observation_child_valid()
returns trigger
language plpgsql
as $$
begin
    perform kpi.assert_observation_valid(coalesce(new.observation_id, old.observation_id));
    return null;
end;
$$;

create constraint trigger observation_contract_ck
    after insert or update on kpi.observation
    deferrable initially deferred
    for each row execute function kpi.tg_assert_observation_valid();

create constraint trigger observation_category_contract_ck
    after insert or update or delete on kpi.observation_category
    deferrable initially deferred
    for each row execute function kpi.tg_assert_observation_child_valid();

create constraint trigger observation_entity_contract_ck
    after insert or update or delete on kpi.observation_entity
    deferrable initially deferred
    for each row execute function kpi.tg_assert_observation_child_valid();

-- -----------------------------------------------------------------------------
-- Trigger: reject observations in a closed reporting period
-- -----------------------------------------------------------------------------

create or replace function kpi.tg_reject_closed_period()
returns trigger
language plpgsql
as $$
begin
    if not exists (select 1 from kpi.reporting_period rp
                    where rp.id = new.reporting_period_id and rp.is_open) then
        raise exception 'reporting period % is closed for data entry', new.reporting_period_id
            using errcode = 'integrity_constraint_violation';
    end if;
    return new;
end;
$$;

create trigger observation_period_open_ck before insert or update on kpi.observation
    for each row execute function kpi.tg_reject_closed_period();

-- -----------------------------------------------------------------------------
-- Trigger: mappings must be structurally and semantically sound
--   * the project must belong to the target program (and program to institution)
--   * child and parent must share one indicator definition, so unit and
--     aggregation method cannot drift between levels
--   * ratio/percentage indicators cannot carry an attribution factor
-- -----------------------------------------------------------------------------

create or replace function kpi.tg_validate_project_contribution()
returns trigger
language plpgsql
as $$
declare
    v_child_program bigint; v_parent_program bigint;
    v_child_def bigint;     v_parent_def bigint;
    v_value_type kpi.value_type;
begin
    select p.program_id, pi.indicator_definition_id, idef.value_type
      into v_child_program, v_child_def, v_value_type
      from kpi.project_indicator pi
      join kpi.project p                 on p.id = pi.project_id
      join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
     where pi.id = new.project_indicator_id;

    select pk.program_id, pk.indicator_definition_id
      into v_parent_program, v_parent_def
      from kpi.program_kpi pk where pk.id = new.program_kpi_id;

    if v_child_program is distinct from v_parent_program then
        raise exception
            'project indicator % is in program %, cannot contribute to a KPI of program %',
            new.project_indicator_id, v_child_program, v_parent_program
            using errcode = 'integrity_constraint_violation';
    end if;

    if v_child_def is distinct from v_parent_def then
        raise exception
            'project indicator % and program KPI % use different indicator definitions (% vs %)',
            new.project_indicator_id, new.program_kpi_id, v_child_def, v_parent_def
            using errcode = 'integrity_constraint_violation';
    end if;

    if v_value_type in ('percentage', 'ratio') and new.contribution_factor <> 1 then
        raise exception
            'contribution_factor must be 1 for % indicators; scale the observation instead',
            v_value_type using errcode = 'integrity_constraint_violation';
    end if;

    return new;
end;
$$;

create trigger project_contribution_ck before insert or update
    on kpi.project_indicator_contribution
    for each row execute function kpi.tg_validate_project_contribution();

create or replace function kpi.tg_validate_program_contribution()
returns trigger
language plpgsql
as $$
declare
    v_child_institution bigint; v_parent_institution bigint;
    v_child_def bigint;         v_parent_def bigint;
    v_value_type kpi.value_type;
begin
    select p.institution_id, pk.indicator_definition_id, idef.value_type
      into v_child_institution, v_child_def, v_value_type
      from kpi.program_kpi pk
      join kpi.program p                 on p.id = pk.program_id
      join kpi.indicator_definition idef on idef.id = pk.indicator_definition_id
     where pk.id = new.program_kpi_id;

    select ik.institution_id, ik.indicator_definition_id
      into v_parent_institution, v_parent_def
      from kpi.institution_kpi ik where ik.id = new.institution_kpi_id;

    if v_child_institution is distinct from v_parent_institution then
        raise exception
            'program KPI % is in institution %, cannot contribute to a KPI of institution %',
            new.program_kpi_id, v_child_institution, v_parent_institution
            using errcode = 'integrity_constraint_violation';
    end if;

    if v_child_def is distinct from v_parent_def then
        raise exception
            'program KPI % and institutional KPI % use different indicator definitions (% vs %)',
            new.program_kpi_id, new.institution_kpi_id, v_child_def, v_parent_def
            using errcode = 'integrity_constraint_violation';
    end if;

    if v_value_type in ('percentage', 'ratio') and new.contribution_factor <> 1 then
        raise exception
            'contribution_factor must be 1 for % indicators; scale the observation instead',
            v_value_type using errcode = 'integrity_constraint_violation';
    end if;

    return new;
end;
$$;

create trigger program_contribution_ck before insert or update
    on kpi.program_kpi_contribution
    for each row execute function kpi.tg_validate_program_contribution();

-- -----------------------------------------------------------------------------
-- Trigger: honour indicator_definition.max_level
-- The org_level enum is ordered institution < program < project, so a KPI may
-- be created at a level only if that level sits at or below the declared ceiling.
-- -----------------------------------------------------------------------------

create or replace function kpi.tg_check_max_level()
returns trigger
language plpgsql
as $$
declare
    v_level     kpi.org_level := tg_argv[0]::kpi.org_level;
    v_max_level kpi.org_level;
begin
    select idef.max_level into v_max_level
      from kpi.indicator_definition idef where idef.id = new.indicator_definition_id;

    if v_level < v_max_level then
        raise exception 'indicator is capped at % level and cannot be used as a % KPI',
            v_max_level, v_level using errcode = 'integrity_constraint_violation';
    end if;
    return new;
end;
$$;

create trigger institution_kpi_level_ck before insert or update on kpi.institution_kpi
    for each row execute function kpi.tg_check_max_level('institution');

create trigger program_kpi_level_ck before insert or update on kpi.program_kpi
    for each row execute function kpi.tg_check_max_level('program');
