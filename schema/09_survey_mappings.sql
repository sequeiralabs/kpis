-- =============================================================================
-- 09_survey_mappings.sql — registers the three sample XLSForms in surveys/
--                          and maps them to project indicators
--
-- These are the mappings documented in docs/Sample-Surveys.md. Loading this
-- makes the examples real: they can be queried, validated against
-- v_indicator_collection_coverage, and used to check a transform.
--
-- Depends on 07 (the demo projects) and 08 (the mapping tables).
-- =============================================================================

set search_path = kpi, public;

-- -----------------------------------------------------------------------------
-- The server
-- -----------------------------------------------------------------------------

insert into kpi.source_system (code, name, platform, base_url, integration_mode, notes)
values ('ODK_CENTRAL', 'Institutional ODK Central', 'odk_central',
        'https://odk.example.org', 'api',
        'Placeholder host. Confirm the deployed Central version and whether the '
        'Entities feature is enabled before relying on Entity Lists.');

-- -----------------------------------------------------------------------------
-- The three published form versions
--
-- One row per version, on purpose: a mapping binds to the version it was
-- validated against, so republishing a form never silently changes the meaning
-- of a historical figure.
-- -----------------------------------------------------------------------------

insert into kpi.source_form (source_system_id, external_project_ref, external_form_id,
                             form_version, title, project_id, published_at)
select s.id, v.central_project, v.form_id, v.version, v.title, p.id,
       timestamptz '2025-01-15 09:00+01'
from kpi.source_system s
join (values
    ('7', 'training_event',     '2025.3', 'Training event (standard module)', 'PRJ-CAS-01'),
    ('7', 'proposal_inclusion', '2025.1', 'Proposal inclusion screening',     'PRJ-SOC-01'),
    ('7', 'variety_trial',      '2025.2', 'Variety trial and release',        'PRJ-CAS-04')
) as v(central_project, form_id, version, title, project_code) on true
join kpi.project p on p.code = v.project_code
where s.code = 'ODK_CENTRAL';

-- -----------------------------------------------------------------------------
-- Form 1 — training_event
--
-- Two rosters, two indicators, both distinct counts, both sex-disaggregated.
-- Note row_filter: attending is not the same as being trained.
-- -----------------------------------------------------------------------------

insert into kpi.source_mapping (
    source_form_id, project_indicator_id, value_mode, repeat_path,
    entity_ref_path, entity_label_path, entity_type,
    observed_on_path, country_path, commodity_path, row_filter,
    mapping_status, effective_from, validated_by, validated_at, note)
select f.id, pi.id, 'distinct_entity',
       v.repeat_path, v.entity_ref, v.entity_label, v.entity_type::kpi.entity_type,
       'event/event_date', 'event/country', 'event/crop', v.row_filter,
       'validated', date '2025-01-01', 'melia.lead', timestamptz '2025-01-15 11:00+01',
       v.note
from kpi.source_form f
join kpi.project_indicator pi on pi.project_id = f.project_id
join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
join (values
    ('KPI_6', 'partner_attendee',   'partner_attendee/partner_id',
     'partner_attendee/partner_name', 'organization',
     'partner_attendee/partner_completed = ''yes''',
     'Delivery partners trained. Attendance alone does not count; only completions.'),
    ('KPI_7', 'scientist_attendee', 'scientist_attendee/scientist_id',
     'scientist_attendee/scientist_name', 'person',
     'scientist_attendee/scientist_completed = ''yes''',
     'National scientists trained, from the second roster on the same form.')
) as v(kpi_code, repeat_path, entity_ref, entity_label, entity_type, row_filter, note)
  on v.kpi_code = idef.code
where f.external_form_id = 'training_event' and f.form_version = '2025.3';

-- Each roster carries its own sex field. The value_map absorbs coding
-- differences so a form never has to be edited to match the KPI catalogue.
insert into kpi.source_mapping_dimension
    (source_mapping_id, dimension_id, field_path, value_map)
select m.id, d.id, v.field_path,
       '{"F":"F","M":"M","other":"OTHER","female":"F","male":"M","1":"F","2":"M"}'::jsonb
from kpi.source_mapping m
join kpi.source_form f on f.id = m.source_form_id
join kpi.project_indicator pi on pi.id = m.project_indicator_id
join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
join kpi.dimension d on d.code = 'SEX'
join (values ('KPI_6', 'partner_attendee/partner_sex'),
             ('KPI_7', 'scientist_attendee/scientist_sex')
) as v(kpi_code, field_path) on v.kpi_code = idef.code
where f.external_form_id = 'training_event' and f.form_version = '2025.3';

-- -----------------------------------------------------------------------------
-- Form 2 — proposal_inclusion
--
-- Three percentage KPIs off one roster of proposals. The numerator differs per
-- KPI; the denominator is the same count of approved proposals every time.
-- No percentage is collected anywhere on the form.
-- -----------------------------------------------------------------------------

insert into kpi.source_mapping (
    source_form_id, project_indicator_id, value_mode,
    value_path, denominator_path, observed_on_path, country_path,
    mapping_status, effective_from, validated_by, validated_at, note)
select f.id, pi.id, 'ratio_fields',
       v.value_path, 'proposals_approved_total',
       'period/reporting_date', 'period/country',
       'validated', date '2025-01-01', 'melia.lead', timestamptz '2025-01-15 11:00+01',
       v.note
from kpi.source_form f
join kpi.project_indicator pi on pi.project_id = f.project_id
join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
join (values
    ('KPI_18', 'proposals_with_inclusion',
     'Gender / youth / social inclusion share of approved proposals.'),
    ('KPI_19', 'proposals_with_climate',
     'Adaptation / mitigation share of approved proposals.'),
    ('KPI_20', 'proposals_with_nutrition',
     'Nutrition and health share of approved proposals.')
) as v(kpi_code, value_path, note) on v.kpi_code = idef.code
where f.external_form_id = 'proposal_inclusion' and f.form_version = '2025.1';

-- -----------------------------------------------------------------------------
-- Form 3 — variety_trial
--
-- Two different patterns on one form: a weighted average and a distinct count.
-- -----------------------------------------------------------------------------

insert into kpi.source_mapping (
    source_form_id, project_indicator_id, value_mode,
    value_path, denominator_path, weight_path,
    observed_on_path, country_path, commodity_path,
    mapping_status, effective_from, validated_by, validated_at, note)
select f.id, pi.id, 'ratio_fields',
       'gain/gain_pct', 'gain/gain_basis', 'gain/trial_count',
       'assessment/assessment_date', 'assessment/country', 'assessment/crop',
       'validated', date '2025-01-01', 'melia.lead', timestamptz '2025-01-15 11:00+01',
       'Genetic gain weighted by trial count. The weight travels upward, so the '
       'program figure stays weighted rather than becoming a simple average.'
from kpi.source_form f
join kpi.project_indicator pi on pi.project_id = f.project_id
join kpi.indicator_definition idef
  on idef.id = pi.indicator_definition_id and idef.code = 'KPI_9'
where f.external_form_id = 'variety_trial' and f.form_version = '2025.2';

insert into kpi.source_mapping (
    source_form_id, project_indicator_id, value_mode, repeat_path,
    entity_ref_path, entity_label_path, entity_type,
    observed_on_path, country_path, commodity_path,
    mapping_status, effective_from, validated_by, validated_at, note)
select f.id, pi.id, 'distinct_entity', 'release',
       'release/variety_id', 'release/variety_name', 'variety',
       'release/release_date', 'assessment/country', 'assessment/crop',
       'validated', date '2025-01-01', 'melia.lead', timestamptz '2025-01-15 11:00+01',
       'Varieties released, de-duplicated by variety. A variety released in two '
       'countries is one variety. Gazette reference required as evidence.'
from kpi.source_form f
join kpi.project_indicator pi on pi.project_id = f.project_id
join kpi.indicator_definition idef
  on idef.id = pi.indicator_definition_id and idef.code = 'KPI_8'
where f.external_form_id = 'variety_trial' and f.form_version = '2025.2';

-- -----------------------------------------------------------------------------
-- Load summary
-- -----------------------------------------------------------------------------

do $$
declare v_forms integer; v_maps integer; v_dims integer;
begin
    select count(*) into v_forms from kpi.source_form;
    select count(*) into v_maps  from kpi.source_mapping where mapping_status = 'validated';
    select count(*) into v_dims  from kpi.source_mapping_dimension;

    raise notice 'survey mappings loaded: % forms, % validated mappings, % dimension bindings',
        v_forms, v_maps, v_dims;

    -- 2 from training_event, 3 from proposal_inclusion, 2 from variety_trial.
    if v_maps <> 7 then
        raise exception 'expected 7 validated mappings, got %', v_maps;
    end if;
end $$;
