-- =============================================================================
-- 04_governance.sql — data-quality framework, ingestion staging, access control,
--                     audit log
--
-- Source: Program KPI Dashboard Framework, sections 8 (layers 3-5),
--         12, 13, 15, 16, 18
--
-- These tables come before the rollup views in 05 because a flagged record is
-- excluded from published KPI figures until its flag is resolved (section 13).
-- =============================================================================

set search_path = kpi, public;

-- -----------------------------------------------------------------------------
-- Ingestion staging (architecture layers 3-4)
--
-- Raw extracted payloads are retained exactly as received, before any
-- transformation, so any published figure can be traced back to the bytes the
-- source platform actually sent.
-- -----------------------------------------------------------------------------

create table kpi.ingestion_batch (
    id              bigint generated always as identity primary key,
    source_system   text not null,             -- the project data-collection platform
    integration_mode text not null,            -- 'api', 'file_etl', 'db_replica'
    source_reference text,                     -- file name, API cursor, export id
    started_at      timestamptz not null default now(),
    completed_at    timestamptz,
    record_count    integer,
    accepted_count  integer,
    flagged_count   integer,
    status          text not null default 'running',  -- running/succeeded/failed
    error_text      text,
    initiated_by    text,
    constraint ingestion_batch_status_ck check (status in ('running', 'succeeded', 'failed'))
);
create index ingestion_batch_started_idx on kpi.ingestion_batch (started_at desc);

create table kpi.staging_record (
    id                 bigint generated always as identity primary key,
    ingestion_batch_id bigint not null references kpi.ingestion_batch (id) on delete cascade,
    source_entity      text not null,          -- 'activity', 'activity_result', 'indicator_value'
    source_record_ref  text,                   -- primary key in the source platform
    payload            jsonb not null,         -- raw, untransformed
    received_at        timestamptz not null default now(),
    processed_at       timestamptz,
    -- Which observation this raw record eventually became, if any.
    observation_id     bigint references kpi.observation (id) on delete set null,
    process_status     text not null default 'pending',
    error_text         text,
    constraint staging_process_status_ck
        check (process_status in ('pending', 'transformed', 'flagged', 'rejected', 'skipped'))
);
create index staging_batch_idx  on kpi.staging_record (ingestion_batch_id);
create index staging_status_idx on kpi.staging_record (process_status);
create index staging_source_idx on kpi.staging_record (source_entity, source_record_ref);
create index staging_payload_idx on kpi.staging_record using gin (payload);

comment on table kpi.staging_record is
    'Raw extracted data retained for traceability before transformation (architecture layer 4).';

-- -----------------------------------------------------------------------------
-- Data-quality framework (framework section 13)
--
-- Rules are configuration, not code, so MELIA/data staff can add checks without
-- a deployment. Failures raise a flag; the record is never silently discarded.
-- -----------------------------------------------------------------------------

create table kpi.dq_rule (
    id            bigint generated always as identity primary key,
    code          text not null unique,        -- 'PCT_RANGE', 'NEGATIVE_COUNT', 'STALE_DATA'
    name          text not null,
    dimension     text not null,               -- completeness/accuracy/consistency/
                                               -- timeliness/validity/uniqueness/integrity
    description   text,
    severity      kpi.dq_severity not null default 'error',
    -- Errors block publication; warnings surface on the dashboard but the value
    -- still publishes.
    blocks_publication boolean not null default true,
    -- Optional narrowing: apply only to one indicator.
    indicator_definition_id bigint references kpi.indicator_definition (id) on delete cascade,
    -- SQL predicate evaluated by the validation job. Kept as text because rules
    -- are authored by data staff at runtime.
    check_expression text,
    is_active     boolean not null default true,
    created_at    timestamptz not null default now(),
    constraint dq_rule_dimension_ck check (dimension in (
        'completeness', 'accuracy', 'consistency', 'timeliness',
        'validity', 'uniqueness', 'integrity'))
);

create table kpi.dq_flag (
    id                 bigint generated always as identity primary key,
    dq_rule_id         bigint not null references kpi.dq_rule (id) on delete restrict,
    -- The flagged record. Observation is the usual target; the others cover
    -- upstream records that never became an observation.
    observation_id     bigint references kpi.observation (id) on delete cascade,
    activity_result_id bigint references kpi.activity_result (id) on delete cascade,
    staging_record_id  bigint references kpi.staging_record (id) on delete cascade,
    entity_id          bigint references kpi.entity (id) on delete cascade,
    status             kpi.dq_flag_status not null default 'open',
    severity           kpi.dq_severity not null,
    detail             text,
    detected_at        timestamptz not null default now(),
    detected_by        text,
    resolved_at        timestamptz,
    resolved_by        text,
    resolution_note    text,
    constraint dq_flag_target_ck check (
        num_nonnulls(observation_id, activity_result_id, staging_record_id, entity_id) = 1
    ),
    constraint dq_flag_resolved_ck check (
        (status in ('resolved', 'waived')) = (resolved_at is not null)
    )
);
create index dq_flag_observation_idx on kpi.dq_flag (observation_id) where observation_id is not null;
create index dq_flag_open_idx        on kpi.dq_flag (status) where status in ('open', 'under_review');
create index dq_flag_rule_idx        on kpi.dq_flag (dq_rule_id);

comment on table kpi.dq_flag is
    'Validation failures. Records are flagged and excluded from published figures, never deleted (framework 13).';

-- Candidate duplicates awaiting a merge decision, ahead of any distinct count
-- (framework 13.1).
create table kpi.entity_duplicate_candidate (
    id             bigint generated always as identity primary key,
    entity_id      bigint not null references kpi.entity (id) on delete cascade,
    duplicate_of_id bigint not null references kpi.entity (id) on delete cascade,
    match_score    numeric(5, 4),
    match_method   text,                       -- 'exact_external_ref', 'canonical_key', 'trigram'
    status         kpi.dq_flag_status not null default 'open',
    reviewed_by    text,
    reviewed_at    timestamptz,
    detected_at    timestamptz not null default now(),
    constraint edc_distinct_ck check (entity_id <> duplicate_of_id),
    constraint edc_score_ck    check (match_score is null or match_score between 0 and 1),
    constraint edc_pair_uq     unique (entity_id, duplicate_of_id)
);
create index edc_open_idx on kpi.entity_duplicate_candidate (status) where status = 'open';

-- -----------------------------------------------------------------------------
-- Data-quality reporting across the seven dimensions (framework section 13)
-- -----------------------------------------------------------------------------

create or replace view kpi.v_dq_dimension_summary as
select
    r.dimension,
    count(*)                                                as total_flags,
    count(*) filter (where f.status = 'open')               as open_flags,
    count(*) filter (where f.status = 'under_review')       as under_review_flags,
    count(*) filter (where f.status = 'resolved')           as resolved_flags,
    count(*) filter (where f.status = 'waived')             as waived_flags,
    count(*) filter (where f.status in ('open', 'under_review')
                       and r.blocks_publication)            as blocking_flags,
    min(f.detected_at)                                      as first_detected_at,
    max(f.detected_at)                                      as last_detected_at
from kpi.dq_flag f
join kpi.dq_rule r on r.id = f.dq_rule_id
group by r.dimension;

comment on view kpi.v_dq_dimension_summary is
    'Flag counts per data-quality dimension: completeness, accuracy, consistency, timeliness, validity, uniqueness, integrity.';

create or replace view kpi.v_dq_flag_detail as
select
    f.id            as dq_flag_id,
    r.dimension,
    r.code          as rule_code,
    r.name          as rule_name,
    f.severity,
    f.status,
    r.blocks_publication,
    f.detail,
    f.detected_at,
    f.resolved_at,
    f.resolution_note,
    prg.name        as program_name,
    prj.name        as project_name,
    idef.code       as indicator_code,
    rp.code         as reporting_period_code,
    o.numerator,
    o.denominator,
    sr.source_entity,
    sr.source_record_ref,
    e.display_name  as entity_name
from kpi.dq_flag f
join kpi.dq_rule r                    on r.id = f.dq_rule_id
left join kpi.observation o           on o.id = f.observation_id
left join kpi.project_indicator pi    on pi.id = o.project_indicator_id
left join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
left join kpi.project prj             on prj.id = pi.project_id
left join kpi.program prg             on prg.id = prj.program_id
left join kpi.reporting_period rp     on rp.id = o.reporting_period_id
left join kpi.staging_record sr       on sr.id = f.staging_record_id
left join kpi.entity e                on e.id = f.entity_id;

-- Ingestion health per batch: how much raw data made it through validation.
create or replace view kpi.v_ingestion_summary as
select
    b.id            as ingestion_batch_id,
    b.source_system,
    b.integration_mode,
    b.started_at,
    b.status,
    count(s.id)                                                as staged_records,
    count(*) filter (where s.process_status = 'transformed')   as transformed,
    count(*) filter (where s.process_status = 'flagged')       as flagged,
    count(*) filter (where s.process_status = 'rejected')      as rejected,
    round(100.0 * count(*) filter (where s.process_status = 'transformed')
          / nullif(count(s.id), 0), 1)                         as acceptance_rate_pct
from kpi.ingestion_batch b
left join kpi.staging_record s on s.ingestion_batch_id = b.id
group by b.id, b.source_system, b.integration_mode, b.started_at, b.status;

-- -----------------------------------------------------------------------------
-- Access control (framework section 15)
--
-- Scoped roles: a program leader sees their program, a project manager their
-- project. Row filtering in the application reads app_user_scope.
-- -----------------------------------------------------------------------------

create table kpi.app_user (
    id            bigint generated always as identity primary key,
    username      text not null unique,
    email         text not null unique,
    full_name     text not null,
    external_idp_ref text,                     -- SSO subject id
    is_active     boolean not null default true,
    last_login_at timestamptz,
    created_at    timestamptz not null default now()
);

create table kpi.app_role (
    id          bigint generated always as identity primary key,
    code        text not null unique,          -- 'EXEC', 'PROGRAM_LEADER', 'MELIA', 'VIEWER'
    name        text not null,
    description text,
    -- Whether this role may see unmasked personal data on entity records.
    can_view_personal_data boolean not null default false
);

create table kpi.app_user_role (
    app_user_id bigint not null references kpi.app_user (id) on delete cascade,
    app_role_id bigint not null references kpi.app_role (id) on delete cascade,
    granted_at  timestamptz not null default now(),
    granted_by  text,
    primary key (app_user_id, app_role_id)
);

-- What slice of the hierarchy a user may see. A row with all three nulls means
-- institution-wide access.
create table kpi.app_user_scope (
    id             bigint generated always as identity primary key,
    app_user_id    bigint not null references kpi.app_user (id) on delete cascade,
    institution_id bigint references kpi.institution (id) on delete cascade,
    program_id     bigint references kpi.program (id) on delete cascade,
    project_id     bigint references kpi.project (id) on delete cascade,
    granted_at     timestamptz not null default now(),
    constraint app_user_scope_ck check (
        num_nonnulls(institution_id, program_id, project_id) <= 1
    )
);
create index app_user_scope_user_idx on kpi.app_user_scope (app_user_id);

-- -----------------------------------------------------------------------------
-- Audit log (framework sections 16, 18)
--
-- Records both data changes and KPI recalculations, so a figure that moves
-- between two board packs can be explained.
-- -----------------------------------------------------------------------------

create table kpi.audit_log (
    id           bigint generated always as identity primary key,
    occurred_at  timestamptz not null default now(),
    app_user_id  bigint references kpi.app_user (id) on delete set null,
    actor        text not null default current_user,
    action       text not null,                -- 'insert', 'update', 'delete', 'recalculate', 'snapshot'
    table_name   text not null,
    record_id    text,
    old_value    jsonb,
    new_value    jsonb,
    reason       text,
    client_ip    inet
);
create index audit_log_time_idx   on kpi.audit_log (occurred_at desc);
create index audit_log_record_idx on kpi.audit_log (table_name, record_id);

-- Generic row-level audit trigger. Attach to the tables whose history matters;
-- it is deliberately not attached to everything, to keep write volume sane.
create or replace function kpi.tg_audit_row()
returns trigger
language plpgsql
as $$
declare
    v_record_id text;
begin
    v_record_id := case tg_op when 'DELETE' then (to_jsonb(old) ->> 'id')
                              else (to_jsonb(new) ->> 'id') end;

    insert into kpi.audit_log (action, table_name, record_id, old_value, new_value)
    values (lower(tg_op),
            tg_table_schema || '.' || tg_table_name,
            v_record_id,
            case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
            case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end);

    return null;
end;
$$;

create trigger observation_audit
    after insert or update or delete on kpi.observation
    for each row execute function kpi.tg_audit_row();

create trigger project_contribution_audit
    after insert or update or delete on kpi.project_indicator_contribution
    for each row execute function kpi.tg_audit_row();

create trigger program_contribution_audit
    after insert or update or delete on kpi.program_kpi_contribution
    for each row execute function kpi.tg_audit_row();

create trigger indicator_definition_audit
    after insert or update or delete on kpi.indicator_definition
    for each row execute function kpi.tg_audit_row();

-- -----------------------------------------------------------------------------
-- Alerts (framework section 17)
-- -----------------------------------------------------------------------------

create table kpi.alert_rule (
    id            bigint generated always as identity primary key,
    code          text not null unique,
    name          text not null,
    alert_type    text not null,               -- performance/reporting/data_quality/target/stale_data
    description   text,
    threshold_value numeric(20, 6),
    -- How many days without a new observation counts as stale.
    stale_after_days integer,
    indicator_definition_id bigint references kpi.indicator_definition (id) on delete cascade,
    is_active     boolean not null default true,
    constraint alert_rule_type_ck check (alert_type in (
        'performance', 'reporting', 'data_quality', 'target', 'stale_data'))
);

create table kpi.alert (
    id            bigint generated always as identity primary key,
    alert_rule_id bigint not null references kpi.alert_rule (id) on delete cascade,
    org_level     kpi.org_level not null,
    institution_kpi_id   bigint references kpi.institution_kpi (id) on delete cascade,
    program_kpi_id       bigint references kpi.program_kpi (id) on delete cascade,
    project_indicator_id bigint references kpi.project_indicator (id) on delete cascade,
    reporting_period_id  bigint references kpi.reporting_period (id) on delete cascade,
    severity      kpi.dq_severity not null default 'warning',
    message       text not null,
    raised_at     timestamptz not null default now(),
    acknowledged_at timestamptz,
    acknowledged_by text,
    constraint alert_target_ck check (
        num_nonnulls(institution_kpi_id, program_kpi_id, project_indicator_id) = 1
    )
);
create index alert_open_idx on kpi.alert (raised_at desc) where acknowledged_at is null;
