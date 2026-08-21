-- =============================================================================
-- 02_indicators.sql — KPI catalogue, the three KPI levels, the KPI Mapping
--                     Table, and multi-year targets
--
-- Source: Program KPI Dashboard Framework, sections 4, 4.1, 10, 10.1, 11
-- =============================================================================

set search_path = kpi, public;

-- -----------------------------------------------------------------------------
-- KPI categories (framework section 4: the five source categories)
-- -----------------------------------------------------------------------------

create table kpi.kpi_category (
    id          bigint generated always as identity primary key,
    code        text not null unique,     -- 'RESEARCH_OUTPUTS'
    name        text not null,            -- 'Research Outputs'
    description text,
    sort_order  smallint not null default 0
);

-- -----------------------------------------------------------------------------
-- Indicator catalogue — the "KPI Inventory" of framework section 4.1
--
-- One definition per metric, reused at every level. Reusing one definition
-- across levels is what makes a rollup meaningful: unit, value type and
-- aggregation method are declared once and cannot drift between levels.
--
-- Fields the source CSV did not supply are nullable and carry an explicit
-- `definition_status`, so the catalogue can be loaded now and completed in the
-- business-rule validation workshop (framework Phase 1, section 23) without
-- pretending the missing values exist.
-- -----------------------------------------------------------------------------

create table kpi.indicator_definition (
    id                  bigint generated always as identity primary key,
    code                text not null unique,        -- 'KPI_6', 'KPI_6A'
    kpi_category_id     bigint references kpi.kpi_category (id) on delete set null,
    name                text not null,
    -- Sub-indicators such as KPI 4a hang off their parent (framework section 4).
    parent_indicator_id bigint references kpi.indicator_definition (id) on delete restrict,

    -- Semantics
    definition_text     text,                        -- the formal "what counts" wording
    numerator_text      text,                        -- framework 4.1
    denominator_text    text,
    value_type          kpi.value_type         not null,
    unit                text,                        -- 'papers', 'partners', '%'
    currency_code       char(3),
    aggregation_method  kpi.aggregation_method not null default 'sum',
    -- Which kind of thing gets de-duplicated when aggregation_method is
    -- distinct_count (framework 6.2, 11.1).
    distinct_entity_type kpi.entity_type,
    direction           kpi.direction not null default 'increase',
    decimal_places      smallint not null default 0,

    -- Cumulative indicators add only the period's increment to the prior
    -- cumulative value; they are never re-summed from history (framework 6.2).
    is_cumulative       boolean not null default false,

    -- The 2025 source figures are indexed/normalised rather than raw counts
    -- (framework 4.2). Flagged so the dashboard never labels them as actuals.
    is_indexed          boolean not null default false,
    index_basis_note    text,

    reporting_frequency kpi.period_type,
    responsible_unit    text,                        -- framework 4.1
    data_source_note    text,
    requires_evidence   boolean not null default false,  -- framework 13.1
    -- Highest level this indicator may be used at. The org_level enum is ordered
    -- institution < program < project.
    max_level           kpi.org_level not null default 'institution',

    -- 'draft' = inferred from the source CSV, pending institutional validation.
    definition_status   kpi.mapping_status not null default 'draft',
    validated_by        text,
    validated_at        timestamptz,

    is_active           boolean not null default true,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),

    constraint indicator_currency_ck check (
        (value_type = 'currency') = (currency_code is not null)
    ),
    -- Never sum a percentage (framework 6.2).
    constraint indicator_ratio_method_ck check (
        value_type not in ('percentage', 'ratio')
        or aggregation_method in ('ratio', 'latest', 'weighted_average')
    ),
    -- distinct_count is meaningless without knowing what is being counted.
    constraint indicator_distinct_entity_ck check (
        (aggregation_method = 'distinct_count') = (distinct_entity_type is not null)
    ),
    constraint indicator_self_parent_ck check (parent_indicator_id is distinct from id),
    constraint indicator_decimals_ck check (decimal_places between 0 and 6),
    -- Validation must be stamped when a definition is validated. A retired
    -- definition keeps its stamp: it records that the definition was approved
    -- once, which is what makes historical figures reproducible.
    constraint indicator_validated_ck check (
        definition_status <> 'validated' or validated_at is not null
    )
);
create index indicator_category_idx on kpi.indicator_definition (kpi_category_id);
create index indicator_parent_idx   on kpi.indicator_definition (parent_indicator_id);
create trigger indicator_definition_touch before update on kpi.indicator_definition
    for each row execute function kpi.set_updated_at();

comment on table kpi.indicator_definition is
    'KPI inventory (framework 4.1). One row per metric, reused at project, program and institutional level.';
comment on column kpi.indicator_definition.is_indexed is
    'True for the indexed 2025 figures (framework 4.2) — display as an index, not a raw count.';

-- Which disaggregation axes apply to an indicator.
create table kpi.indicator_dimension (
    indicator_definition_id bigint not null references kpi.indicator_definition (id) on delete cascade,
    dimension_id            bigint not null references kpi.dimension (id) on delete restrict,
    -- required: every observation must carry a category on this axis
    -- optional: observations may carry it; rollups still group by it
    is_required             boolean not null default true,
    primary key (indicator_definition_id, dimension_id)
);

comment on table kpi.indicator_dimension is
    'Disaggregation contract. Required axes are enforced on observation insert (see 03).';

-- -----------------------------------------------------------------------------
-- Level 3 — Project indicator
-- -----------------------------------------------------------------------------

create table kpi.project_indicator (
    id                      bigint generated always as identity primary key,
    project_id              bigint not null references kpi.project (id) on delete cascade,
    indicator_definition_id bigint not null references kpi.indicator_definition (id) on delete restrict,
    work_package_id         bigint references kpi.work_package (id) on delete set null,
    local_name              text,                    -- 'Partners trained - Component A'
    data_source             kpi.data_source not null default 'activity_rollup',
    baseline_value          numeric(20, 6),
    baseline_date           date,
    responsible             text,
    is_active               boolean not null default true,
    created_at              timestamptz not null default now(),
    updated_at              timestamptz not null default now(),
    constraint project_indicator_uq unique (project_id, indicator_definition_id, work_package_id)
);
create index project_indicator_project_idx    on kpi.project_indicator (project_id);
create index project_indicator_definition_idx on kpi.project_indicator (indicator_definition_id);
create trigger project_indicator_touch before update on kpi.project_indicator
    for each row execute function kpi.set_updated_at();

-- -----------------------------------------------------------------------------
-- Level 2 — Program KPI
-- -----------------------------------------------------------------------------

create table kpi.program_kpi (
    id                      bigint generated always as identity primary key,
    program_id              bigint not null references kpi.program (id) on delete cascade,
    indicator_definition_id bigint not null references kpi.indicator_definition (id) on delete restrict,
    local_name              text,
    baseline_value          numeric(20, 6),
    baseline_date           date,
    scorecard_weight        numeric(9, 4) not null default 1,
    responsible             text,
    is_active               boolean not null default true,
    created_at              timestamptz not null default now(),
    updated_at              timestamptz not null default now(),
    constraint program_kpi_uq unique (program_id, indicator_definition_id),
    constraint program_kpi_weight_ck check (scorecard_weight >= 0)
);
create index program_kpi_program_idx on kpi.program_kpi (program_id);
create trigger program_kpi_touch before update on kpi.program_kpi
    for each row execute function kpi.set_updated_at();

-- -----------------------------------------------------------------------------
-- Level 1 — Institutional KPI
-- -----------------------------------------------------------------------------

create table kpi.institution_kpi (
    id                      bigint generated always as identity primary key,
    institution_id          bigint not null references kpi.institution (id) on delete cascade,
    indicator_definition_id bigint not null references kpi.indicator_definition (id) on delete restrict,
    local_name              text,
    strategic_objective     text,
    baseline_value          numeric(20, 6),
    baseline_date           date,
    scorecard_weight        numeric(9, 4) not null default 1,
    responsible             text,
    is_active               boolean not null default true,
    created_at              timestamptz not null default now(),
    updated_at              timestamptz not null default now(),
    constraint institution_kpi_uq unique (institution_id, indicator_definition_id),
    constraint institution_kpi_weight_ck check (scorecard_weight >= 0)
);
create index institution_kpi_institution_idx on kpi.institution_kpi (institution_id);
create trigger institution_kpi_touch before update on kpi.institution_kpi
    for each row execute function kpi.set_updated_at();

-- -----------------------------------------------------------------------------
-- The KPI Mapping Table (framework section 10.1)
--
-- Many-to-many on purpose: several project indicators feed one program KPI, and
-- one project indicator can feed more than one.
--
--   contribution_factor  unit conversion and/or attribution share applied to the
--                        child's numerator. Must be 1 for ratio/percentage
--                        indicators — scaling a numerator without its
--                        denominator would change the ratio (see 03).
--   weight               used only when the parent aggregates by weighted_average
--   effective_from/to    mappings are versioned, never overwritten, so historical
--                        figures stay reproducible (framework 10.1)
-- -----------------------------------------------------------------------------

create table kpi.project_indicator_contribution (
    id                   bigint generated always as identity primary key,
    project_indicator_id bigint not null references kpi.project_indicator (id) on delete cascade,
    program_kpi_id       bigint not null references kpi.program_kpi (id) on delete cascade,
    contribution_factor  numeric(18, 6) not null default 1,
    weight               numeric(18, 6) not null default 1,
    effective_from       date,
    effective_to         date,
    mapping_status       kpi.mapping_status not null default 'draft',
    validated_by         text,
    validated_at         timestamptz,
    note                 text,
    created_at           timestamptz not null default now(),
    constraint pic_weight_ck check (weight >= 0),
    constraint pic_dates_ck  check (effective_to is null or effective_from is null
                                    or effective_to >= effective_from),
    constraint pic_validated_ck check (
        mapping_status <> 'validated' or validated_at is not null
    )
);
-- One live mapping per pair; retired versions may coexist as history.
create unique index pic_live_uq
    on kpi.project_indicator_contribution (project_indicator_id, program_kpi_id)
    where mapping_status <> 'retired';
create index pic_program_kpi_idx on kpi.project_indicator_contribution (program_kpi_id);

create table kpi.program_kpi_contribution (
    id                  bigint generated always as identity primary key,
    program_kpi_id      bigint not null references kpi.program_kpi (id) on delete cascade,
    institution_kpi_id  bigint not null references kpi.institution_kpi (id) on delete cascade,
    contribution_factor numeric(18, 6) not null default 1,
    weight              numeric(18, 6) not null default 1,
    effective_from      date,
    effective_to        date,
    mapping_status      kpi.mapping_status not null default 'draft',
    validated_by        text,
    validated_at        timestamptz,
    note                text,
    created_at          timestamptz not null default now(),
    constraint pkc_weight_ck check (weight >= 0),
    constraint pkc_dates_ck  check (effective_to is null or effective_from is null
                                    or effective_to >= effective_from),
    constraint pkc_validated_ck check (
        mapping_status <> 'validated' or validated_at is not null
    )
);
create unique index pkc_live_uq
    on kpi.program_kpi_contribution (program_kpi_id, institution_kpi_id)
    where mapping_status <> 'retired';
create index pkc_institution_kpi_idx on kpi.program_kpi_contribution (institution_kpi_id);

-- -----------------------------------------------------------------------------
-- Targets (framework 4.1: annual target + cumulative target, 2025-2030)
--
-- Separate tables per level rather than one polymorphic table, so the foreign
-- keys are real. disaggregation_key = '' is the overall target; a non-empty key
-- targets a single slice (e.g. a female-participation sub-target).
-- -----------------------------------------------------------------------------

create table kpi.project_indicator_target (
    project_indicator_id bigint not null references kpi.project_indicator (id) on delete cascade,
    reporting_period_id  bigint not null references kpi.reporting_period (id) on delete cascade,
    disaggregation_key   text not null default '',
    target_value         numeric(20, 6) not null,
    cumulative_target    numeric(20, 6),
    note                 text,
    created_at           timestamptz not null default now(),
    primary key (project_indicator_id, reporting_period_id, disaggregation_key)
);

create table kpi.program_kpi_target (
    program_kpi_id      bigint not null references kpi.program_kpi (id) on delete cascade,
    reporting_period_id bigint not null references kpi.reporting_period (id) on delete cascade,
    disaggregation_key  text not null default '',
    target_value        numeric(20, 6) not null,
    cumulative_target   numeric(20, 6),
    note                text,
    created_at          timestamptz not null default now(),
    primary key (program_kpi_id, reporting_period_id, disaggregation_key)
);

create table kpi.institution_kpi_target (
    institution_kpi_id  bigint not null references kpi.institution_kpi (id) on delete cascade,
    reporting_period_id bigint not null references kpi.reporting_period (id) on delete cascade,
    disaggregation_key  text not null default '',
    target_value        numeric(20, 6) not null,
    cumulative_target   numeric(20, 6),
    note                text,
    created_at          timestamptz not null default now(),
    primary key (institution_kpi_id, reporting_period_id, disaggregation_key)
);

-- Traffic-light thresholds (framework section 14: on track / at risk / off track).
create table kpi.performance_band (
    id             bigint generated always as identity primary key,
    code           text not null unique,       -- 'ON_TRACK', 'AT_RISK', 'OFF_TRACK'
    label          text not null,
    min_achievement numeric(8, 4),             -- inclusive lower bound, % of target
    max_achievement numeric(8, 4),             -- exclusive upper bound
    colour_hex     char(7),
    sort_order     smallint not null default 0,
    constraint performance_band_range_ck check (
        min_achievement is null or max_achievement is null
        or max_achievement > min_achievement
    )
);
