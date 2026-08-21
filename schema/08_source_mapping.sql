-- =============================================================================
-- 08_source_mapping.sql — binding collection forms to project indicators
--
-- Framework section 10 defines a KPI Mapping Table between project indicators
-- and program KPIs. This file adds the layer below it: how a submission from a
-- data-collection platform (ODK Central, or any other) becomes an observation
-- against a project indicator.
--
-- The design deliberately does NOT map individual questions to KPIs. It maps a
-- FORM MODULE to an indicator, and names the few paths within that module that
-- carry meaning. Forms churn; the shape of "a training event happened, here are
-- the attendees" does not.
--
-- See docs/ODK-Central-Integration.md for the full process.
-- =============================================================================

set search_path = kpi, public;

-- How a mapped module turns submission rows into a numerator.
create type kpi.source_value_mode as enum (
    'count_rows',      -- one row per thing counted (a roster repeat group)
    'distinct_entity', -- like count_rows, but rows resolve to registry entities
    'sum_field',       -- add a numeric field across rows
    'value_field',     -- take a single field from the submission
    'ratio_fields'     -- numerator and denominator both read from fields
);

-- -----------------------------------------------------------------------------
-- Source systems and forms
-- -----------------------------------------------------------------------------

create table kpi.source_system (
    id            bigint generated always as identity primary key,
    code          text not null unique,          -- 'ODK_CENTRAL'
    name          text not null,
    platform      text not null,                 -- 'odk_central', 'excel', 'rest_api'
    base_url      text,
    -- How records are pulled: framework section 12's three integration patterns.
    integration_mode text not null default 'api',
    notes         text,
    is_active     boolean not null default true,
    created_at    timestamptz not null default now(),
    constraint source_system_mode_ck
        check (integration_mode in ('api', 'file_etl', 'db_replica'))
);

-- One row per form VERSION. Mappings are bound to a version, so a form revision
-- can never silently change what a historical figure meant.
create table kpi.source_form (
    id               bigint generated always as identity primary key,
    source_system_id bigint not null references kpi.source_system (id) on delete cascade,
    -- ODK Central: the project id and xmlFormId.
    external_project_ref text,
    external_form_id text not null,
    form_version     text not null,
    title            text not null,
    -- A form owned by one project, or null for an institution-wide module.
    project_id       bigint references kpi.project (id) on delete set null,
    published_at     timestamptz,
    is_active        boolean not null default true,
    created_at       timestamptz not null default now(),
    constraint source_form_uq unique (source_system_id, external_form_id, form_version)
);
create index source_form_project_idx on kpi.source_form (project_id);

-- Optional: the fields discovered from the published form definition. Populated
-- by the integration job so mappings can be validated against the real schema
-- rather than against a path someone typed from memory.
create table kpi.source_form_field (
    id             bigint generated always as identity primary key,
    source_form_id bigint not null references kpi.source_form (id) on delete cascade,
    path           text not null,               -- 'training/attendees/sex'
    data_type      text,                        -- 'string', 'int', 'select_one', 'repeat'
    label          text,
    is_repeat      boolean not null default false,
    constraint source_form_field_uq unique (source_form_id, path)
);

-- -----------------------------------------------------------------------------
-- The mapping itself
--
-- One row binds a form version to one project indicator. Everything the
-- transform needs is named here as a path into the submission.
-- -----------------------------------------------------------------------------

create table kpi.source_mapping (
    id                   bigint generated always as identity primary key,
    source_form_id       bigint not null references kpi.source_form (id) on delete cascade,
    project_indicator_id bigint not null references kpi.project_indicator (id) on delete cascade,

    value_mode           kpi.source_value_mode not null,

    -- For roster-based modes: the repeat group whose rows are counted.
    -- Null means the submission itself is the single row.
    repeat_path          text,
    -- Where the number comes from, for sum_field / value_field / ratio_fields.
    value_path           text,
    denominator_path     text,
    -- Weight for weighted-average indicators (KPI 9: trial or plot count).
    weight_path          text,

    -- For distinct_entity: the stable identifier and the registry type it
    -- resolves to. entity_label_path is used only when creating a new registry
    -- record for an unseen identifier.
    entity_ref_path      text,
    entity_label_path    text,
    entity_type          kpi.entity_type,

    -- Context and timing.
    observed_on_path     text,
    country_path         text,
    commodity_path       text,
    -- Optional row filter, e.g. only attendees who completed the course.
    row_filter           text,

    -- Versioned exactly like the KPI mapping table above it.
    mapping_status       kpi.mapping_status not null default 'draft',
    effective_from       date,
    effective_to         date,
    validated_by         text,
    validated_at         timestamptz,
    note                 text,
    created_at           timestamptz not null default now(),
    updated_at           timestamptz not null default now(),

    constraint source_mapping_validated_ck
        check (mapping_status <> 'validated' or validated_at is not null),
    constraint source_mapping_dates_ck
        check (effective_to is null or effective_from is null
               or effective_to >= effective_from),
    -- Each mode needs its own paths and nothing else is meaningful.
    constraint source_mapping_mode_ck check (
        case value_mode
            when 'count_rows'      then repeat_path is not null
            when 'distinct_entity' then repeat_path is not null
                                    and entity_ref_path is not null
                                    and entity_type is not null
            when 'sum_field'       then value_path is not null
            when 'value_field'     then value_path is not null
            when 'ratio_fields'    then value_path is not null
                                    and denominator_path is not null
        end
    )
);
create unique index source_mapping_live_uq
    on kpi.source_mapping (source_form_id, project_indicator_id)
    where mapping_status <> 'retired';
create index source_mapping_indicator_idx on kpi.source_mapping (project_indicator_id);
create trigger source_mapping_touch before update on kpi.source_mapping
    for each row execute function kpi.set_updated_at();

comment on table kpi.source_mapping is
    'Binds one form version to one project indicator. Maps modules, not questions — see docs/ODK-Central-Integration.md.';

-- How a form answer becomes a disaggregation category.
--
-- value_map holds the answer-to-category translation, e.g.
--   {"female": "F", "male": "M", "1": "F", "2": "M"}
-- so a form that codes sex differently from the KPI catalogue still lands in
-- the right slice without anyone editing the form.
create table kpi.source_mapping_dimension (
    source_mapping_id bigint not null references kpi.source_mapping (id) on delete cascade,
    dimension_id      bigint not null references kpi.dimension (id) on delete restrict,
    field_path        text not null,
    value_map         jsonb not null default '{}'::jsonb,
    -- Category used when the answer is blank or unrecognised. Null means the
    -- row is flagged rather than silently bucketed.
    fallback_category_id bigint references kpi.dimension_category (id) on delete set null,
    primary key (source_mapping_id, dimension_id)
);

comment on column kpi.source_mapping_dimension.value_map is
    'Answer value -> dimension_category.code. Lets each form keep its own coding while landing in the right slice.';

-- -----------------------------------------------------------------------------
-- Submission-level provenance
--
-- ODK Central guarantees a stable instanceID per submission. Recording it makes
-- re-ingestion idempotent: pulling the same submission twice updates the same
-- observation instead of double counting it.
-- -----------------------------------------------------------------------------

create table kpi.source_submission (
    id                 bigint generated always as identity primary key,
    source_form_id     bigint not null references kpi.source_form (id) on delete cascade,
    instance_id        text not null,             -- ODK instanceID (uuid:...)
    submitter          text,
    submitted_at       timestamptz,
    -- Central's own review state, mapped onto our approval workflow.
    review_state       text,                      -- null/edited/hasIssues/rejected/approved
    ingestion_batch_id bigint references kpi.ingestion_batch (id) on delete set null,
    staging_record_id  bigint references kpi.staging_record (id) on delete set null,
    processed_at       timestamptz,
    constraint source_submission_uq unique (source_form_id, instance_id)
);
create index source_submission_batch_idx on kpi.source_submission (ingestion_batch_id);

-- Which observations a submission produced. One submission commonly produces
-- several: one per indicator, per disaggregation slice.
create table kpi.source_submission_observation (
    source_submission_id bigint not null references kpi.source_submission (id) on delete cascade,
    observation_id       bigint not null references kpi.observation (id) on delete cascade,
    source_mapping_id    bigint references kpi.source_mapping (id) on delete set null,
    primary key (source_submission_id, observation_id)
);
create index ssobs_observation_idx on kpi.source_submission_observation (observation_id);

-- -----------------------------------------------------------------------------
-- Coverage view: which project indicators actually have a collection route
--
-- An indicator with no validated mapping and no direct-entry route will never
-- receive data. That is a reporting gap worth surfacing before the period
-- closes, not after.
-- -----------------------------------------------------------------------------

create or replace view kpi.v_indicator_collection_coverage as
select
    prg.name        as program_name,
    prj.code        as project_code,
    prj.name        as project_name,
    idef.code       as indicator_code,
    idef.name       as indicator_name,
    pi.data_source,
    count(m.id) filter (where m.mapping_status = 'validated') as validated_mappings,
    count(m.id) filter (where m.mapping_status = 'draft')     as draft_mappings,
    case
        when count(m.id) filter (where m.mapping_status = 'validated') > 0 then 'mapped'
        when pi.data_source <> 'activity_rollup' then 'manual entry'
        else 'NO COLLECTION ROUTE'
    end as coverage
from kpi.project_indicator pi
join kpi.project prj               on prj.id = pi.project_id
join kpi.program prg               on prg.id = prj.program_id
join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
left join kpi.source_mapping m     on m.project_indicator_id = pi.id
where pi.is_active
group by prg.name, prj.code, prj.name, idef.code, idef.name, pi.data_source;

comment on view kpi.v_indicator_collection_coverage is
    'Project indicators with no route for data to arrive — a reporting gap to close before a period closes.';
