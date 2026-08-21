-- =============================================================================
-- 01_core.sql — schema, enumerated types, organisation hierarchy,
--               reporting calendar, reference dimensions, disaggregation axes
--
-- Target: PostgreSQL 14+
-- Source: Program KPI Dashboard Framework, sections 2, 6, 9.1, 9.2
--
-- There is one institution. The institution table still exists as the top
-- of the hierarchy (it anchors institutional KPIs and their targets), but it is
-- expected to hold exactly one row.
-- =============================================================================

create schema if not exists kpi;
set search_path = kpi, public;

-- -----------------------------------------------------------------------------
-- Enumerated types
-- -----------------------------------------------------------------------------

create type kpi.org_level as enum ('institution', 'program', 'project');

create type kpi.value_type as enum (
    'count',        -- whole things: papers, varieties released
    'decimal',      -- continuous quantity
    'currency',
    'percentage',   -- numerator/denominator rendered 0-100 (KPI 4a-7a, 9, 10, 18-20)
    'ratio',        -- numerator/denominator rendered as-is (KPI 2: papers per IRS)
    'index_score'   -- the indexed/normalised figures in the 2025 source file
);

-- Framework section 11: the six aggregation methods. `cumulative` is modelled
-- separately (indicator_definition.is_cumulative) because it describes how a
-- KPI accumulates across TIME, not how children combine into a parent.
create type kpi.aggregation_method as enum (
    'sum',              -- Simple Sum (KPI 1, 3, 8, 15, 16, 17)
    'distinct_count',   -- COUNT(DISTINCT entity_id) (KPI 4, 5, 6, 7, 11, 12, 13, 14)
    'ratio',            -- Numerator / Denominator (KPI 2, 4a-7a, 10, 18, 19, 20)
    'weighted_average', -- Sum(w*x)/Sum(w) (KPI 9)
    'latest',           -- most recent validated observation (KPI 10)
    'average',
    'max',
    'min'
);

create type kpi.direction as enum ('increase', 'decrease', 'maintain');

create type kpi.period_type as enum ('month', 'quarter', 'semester', 'year', 'custom');

create type kpi.data_source as enum (
    'activity_rollup',  -- derived from recorded activity results
    'direct_entry',     -- survey, census, manual MELIA entry
    'external_system',  -- imported from the project data-collection platform
    'calculated'        -- formula over other indicators
);

-- Framework section 13: records that fail validation are flagged, never deleted,
-- and are excluded from published figures until resolved.
create type kpi.approval_status as enum (
    'draft', 'submitted', 'validated', 'rejected', 'superseded'
);

-- Framework section 10.1: mappings are versioned, not overwritten.
create type kpi.mapping_status as enum ('draft', 'validated', 'retired');

create type kpi.lifecycle_status as enum (
    'planned', 'active', 'on_hold', 'completed', 'cancelled'
);

-- Framework section 11.1 / 13.1: the countable things that must not be
-- double-counted when the same one is reported by more than one project.
create type kpi.entity_type as enum (
    'person',            -- students (KPI 4, 5), national scientists (KPI 7)
    'organization',      -- delivery partners (KPI 6), scaling partners (KPI 14), ARIs (KPI 13)
    'publication',       -- KPI 1, 2, 3
    'thesis',            -- KPI 5
    'variety',           -- KPI 8
    'innovation',        -- KPI 11, 12
    'engagement_event',  -- KPI 17
    'award',             -- KPI 15
    'proposal'           -- KPI 18, 19, 20
);

create type kpi.dq_flag_status as enum ('open', 'under_review', 'resolved', 'waived');

create type kpi.dq_severity as enum ('info', 'warning', 'error');

-- -----------------------------------------------------------------------------
-- Shared audit trigger
-- -----------------------------------------------------------------------------

create or replace function kpi.set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Reference dimensions (framework 9.1, 9.2: DIM_GEOGRAPHY, DIM_COMMODITY,
-- DIM_PARTNER)
--
-- These describe the CONTEXT of a result — where, on which crop, with whom.
-- They are drill-down and filter axes, not part of an indicator's disaggregation
-- contract, so they hang off observations as nullable foreign keys rather than
-- entering the disaggregation key.
-- -----------------------------------------------------------------------------

create table kpi.country (
    id            bigint generated always as identity primary key,
    iso3166_alpha2 char(2) not null unique,   -- framework 13.1: coded, never free text
    iso3166_alpha3 char(3) unique,
    name          text not null,
    region        text,                        -- 'West Africa', 'East & Southern Africa'
    is_active     boolean not null default true
);

create table kpi.location (
    id          bigint generated always as identity primary key,
    country_id  bigint not null references kpi.country (id) on delete restrict,
    code        text   not null,
    name        text   not null,
    admin_level smallint,                      -- 1 = state/province, 2 = LGA/district
    parent_id   bigint references kpi.location (id) on delete set null,
    latitude    numeric(9, 6),
    longitude   numeric(9, 6),
    is_active   boolean not null default true,
    constraint location_code_per_country_uq unique (country_id, code),
    constraint location_latitude_ck  check (latitude  is null or latitude  between -90 and 90),
    constraint location_longitude_ck check (longitude is null or longitude between -180 and 180)
);
create index location_country_idx on kpi.location (country_id);
create index location_parent_idx  on kpi.location (parent_id);

create table kpi.commodity (
    id         bigint generated always as identity primary key,
    code       text not null unique,          -- 'CASSAVA', 'YAM', 'COWPEA', 'MAIZE'
    name       text not null,
    crop_group text,
    is_active  boolean not null default true
);

create table kpi.partner (
    id            bigint generated always as identity primary key,
    code          text not null unique,
    name          text not null,
    partner_type  text,                        -- 'ARI', 'NARS', 'Scaling', 'Private sector'
    country_id    bigint references kpi.country (id) on delete set null,
    external_ref  text,                        -- ROR ID, registration number
    is_active     boolean not null default true,
    created_at    timestamptz not null default now()
);
create index partner_country_idx on kpi.partner (country_id);

-- -----------------------------------------------------------------------------
-- Organisation hierarchy (framework section 2)
--   Institution > Program > Project > Work Package > Activity
-- -----------------------------------------------------------------------------

create table kpi.institution (
    id            bigint generated always as identity primary key,
    code          text        not null,
    name          text        not null,
    description   text,
    country_id    bigint references kpi.country (id) on delete set null,
    is_active     boolean     not null default true,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    constraint institution_code_ck check (code = trim(code) and code <> '')
);
create unique index institution_code_uq on kpi.institution (lower(code));

create table kpi.program (
    id             bigint generated always as identity primary key,
    institution_id bigint not null references kpi.institution (id) on delete restrict,
    code           text   not null,
    name           text   not null,
    description    text,
    program_leader text,
    start_date     date,
    end_date       date,
    status         kpi.lifecycle_status not null default 'active',
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now(),
    constraint program_code_uq unique (institution_id, code),
    constraint program_dates_ck check (end_date is null or start_date is null
                                       or end_date >= start_date)
);
create index program_institution_idx on kpi.program (institution_id);

create table kpi.project (
    id              bigint generated always as identity primary key,
    program_id      bigint not null references kpi.program (id) on delete restrict,
    code            text   not null,
    name            text   not null,
    description     text,
    project_manager text,
    donor           text,
    start_date      date,
    end_date        date,
    status          kpi.lifecycle_status not null default 'active',
    budget_amount   numeric(18, 2),
    budget_currency char(3) default 'USD',
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    constraint project_code_uq unique (program_id, code),
    constraint project_dates_ck check (end_date is null or start_date is null
                                       or end_date >= start_date)
);
create index project_program_idx on kpi.project (program_id);

-- Optional intermediate grouping (framework section 2: "where applicable").
create table kpi.work_package (
    id          bigint generated always as identity primary key,
    project_id  bigint not null references kpi.project (id) on delete cascade,
    code        text   not null,
    name        text   not null,
    description text,
    lead        text,
    created_at  timestamptz not null default now(),
    constraint work_package_code_uq unique (project_id, code)
);
create index work_package_project_idx on kpi.work_package (project_id);

-- Many-to-many context links (framework 9.1).
create table kpi.project_country (
    project_id bigint not null references kpi.project (id) on delete cascade,
    country_id bigint not null references kpi.country (id) on delete restrict,
    primary key (project_id, country_id)
);

create table kpi.project_commodity (
    project_id   bigint not null references kpi.project (id) on delete cascade,
    commodity_id bigint not null references kpi.commodity (id) on delete restrict,
    primary key (project_id, commodity_id)
);

create table kpi.project_partner (
    project_id bigint not null references kpi.project (id) on delete cascade,
    partner_id bigint not null references kpi.partner (id) on delete restrict,
    role       text,
    primary key (project_id, partner_id)
);

create trigger institution_touch before update on kpi.institution
    for each row execute function kpi.set_updated_at();
create trigger program_touch before update on kpi.program
    for each row execute function kpi.set_updated_at();
create trigger project_touch before update on kpi.project
    for each row execute function kpi.set_updated_at();

comment on table kpi.institution  is 'Top of the hierarchy (the institution). Expected to hold exactly one row.';
comment on table kpi.program      is 'Owns projects and program-level KPIs.';
comment on table kpi.project      is 'Delivery unit. Implements activities and owns project indicators.';
comment on table kpi.work_package is 'Optional component grouping between project and activity.';

-- -----------------------------------------------------------------------------
-- Reporting calendar (framework 9.1: Reporting_Periods, DIM_TIME)
--
-- Periods nest via parent_period_id (2026-Q1 -> FY2026), so projects can report
-- quarterly while the institution reports annually off the same observations.
-- -----------------------------------------------------------------------------

create table kpi.reporting_period (
    id               bigint generated always as identity primary key,
    code             text   not null unique,        -- '2026-Q1', 'FY2026'
    name             text   not null,
    period_type      kpi.period_type not null,
    fiscal_year      smallint not null,
    start_date       date   not null,
    end_date         date   not null,
    parent_period_id bigint references kpi.reporting_period (id) on delete set null,
    is_open          boolean not null default true,  -- data-entry gate
    published_at     timestamptz,
    created_at       timestamptz not null default now(),
    constraint reporting_period_dates_ck check (end_date >= start_date),
    constraint reporting_period_self_parent_ck check (parent_period_id is distinct from id)
);
create index reporting_period_range_idx  on kpi.reporting_period (start_date, end_date);
create index reporting_period_parent_idx on kpi.reporting_period (parent_period_id);
create index reporting_period_year_idx   on kpi.reporting_period (fiscal_year, period_type);

comment on column kpi.reporting_period.is_open is
    'Closed periods reject new observations but still accept snapshots.';

-- -----------------------------------------------------------------------------
-- Disaggregation axes (framework 4.1: "Sex-disaggregation implied for KPIs 4-7")
--
-- A dimension is an axis (Sex, Age band, Degree level); a category is a value on
-- it. Indicators declare which axes apply; observations carry one category per
-- applicable axis. Adding a new axis is data entry, not a migration.
-- -----------------------------------------------------------------------------

create table kpi.dimension (
    id          bigint generated always as identity primary key,
    code        text not null unique,       -- 'SEX', 'AGE_BAND', 'DEGREE_LEVEL'
    name        text not null,
    description text,
    sort_order  smallint not null default 0,
    is_active   boolean not null default true
);

create table kpi.dimension_category (
    id           bigint generated always as identity primary key,
    dimension_id bigint not null references kpi.dimension (id) on delete cascade,
    code         text not null,             -- 'F', 'M', 'YOUTH'
    label        text not null,
    sort_order   smallint not null default 0,
    is_active    boolean not null default true,
    constraint dimension_category_code_uq unique (dimension_id, code),
    -- Composite target so observation_category can prove a category actually
    -- belongs to the dimension it is filed under.
    constraint dimension_category_id_dim_uq unique (id, dimension_id)
);
create index dimension_category_dimension_idx on kpi.dimension_category (dimension_id);
