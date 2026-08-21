-- =============================================================================
-- 10_comments.sql — table and column documentation
--
-- Descriptions live in the database rather than only in a Markdown file, so
-- psql (\d+), Adminer and any BI tool that reads catalogue comments all see
-- them. docs/Schema-Reference.md is generated from this metadata by
-- tools/build_schema_docs.py, which makes the document a projection of the
-- schema rather than a parallel copy that can drift.
--
-- Self-evident columns (id, code, name, created_at, updated_at, is_active) are
-- generally left uncommented; the generated reference still lists them with
-- their type, nullability, default and foreign key.
-- =============================================================================

set search_path = kpi, public;

-- =============================================================================
-- Reference dimensions
-- =============================================================================

comment on table kpi.country is
    'ISO 3166 country reference. Framework 13.1 requires coded geography rather than free text.';
comment on column kpi.country.iso3166_alpha2 is 'Two-letter ISO 3166-1 code; the natural key.';
comment on column kpi.country.region is 'Operating region grouping, e.g. West Africa.';

comment on table kpi.location is
    'Sub-national places within a country, nested to any depth via parent_id.';
comment on column kpi.location.admin_level is '1 = state or province, 2 = LGA or district.';
comment on column kpi.location.parent_id is 'Containing location, for admin hierarchies.';

comment on table kpi.commodity is 'Crops and value chains used to slice results.';
comment on column kpi.commodity.crop_group is 'Grouping such as roots and tubers, or grain legumes.';

comment on table kpi.partner is
    'Partner organisations: delivery partners, ARIs, scaling partners, private sector.';
comment on column kpi.partner.partner_type is 'ARI, NARS, Scaling, Private sector.';
comment on column kpi.partner.external_ref is 'Authoritative external identifier, e.g. a ROR id.';

-- =============================================================================
-- Organisation hierarchy
-- =============================================================================

comment on table kpi.institution is
    'Top of the hierarchy (the institution). Expected to hold exactly one row; it anchors institutional KPIs and their targets.';

comment on table kpi.program is
    'A program groups projects and owns program-level KPIs.';
comment on column kpi.program.program_leader is 'Named accountable owner for the program scorecard.';

comment on table kpi.project is
    'Delivery unit. Implements activities and owns project indicators.';
comment on column kpi.project.donor is 'Funder, for donor reporting and filtering.';
comment on column kpi.project.budget_amount is 'Indicative project budget; not used in KPI calculation.';

comment on table kpi.work_package is
    'Optional component grouping between project and activity, used where a project is structured into work packages.';

comment on table kpi.project_country is 'Countries a project operates in (many-to-many).';
comment on table kpi.project_commodity is 'Commodities a project works on (many-to-many).';
comment on table kpi.project_partner is 'Partner organisations attached to a project.';
comment on column kpi.project_partner.role is 'How the partner participates, e.g. implementing or scaling.';

-- =============================================================================
-- Reporting calendar
-- =============================================================================

comment on table kpi.reporting_period is
    'Shared reporting calendar. Periods nest via parent_period_id (2025-Q1 -> FY2025), so projects can report quarterly while the institution reports annually off the same observations.';
comment on column kpi.reporting_period.period_type is 'Granularity: month, quarter, semester, year or custom.';
comment on column kpi.reporting_period.fiscal_year is 'Financial year the period belongs to.';
comment on column kpi.reporting_period.parent_period_id is
    'The period that contains this one. Drives v_period_rollup, which lets one observation serve every enclosing period.';
comment on column kpi.reporting_period.is_open is
    'Data-entry gate. Closed periods reject new observations but still accept snapshots.';
comment on column kpi.reporting_period.published_at is 'When results for this period were released.';

-- =============================================================================
-- Disaggregation axes
-- =============================================================================

comment on table kpi.dimension is
    'A disaggregation axis such as sex, age band or degree level. Adding an axis is data entry, not a migration.';

comment on table kpi.dimension_category is
    'A value on a disaggregation axis, e.g. F or M on the SEX axis.';
comment on column kpi.dimension_category.code is
    'Short code that appears in observation.disaggregation_key.';

-- =============================================================================
-- KPI catalogue
-- =============================================================================

comment on table kpi.kpi_category is
    'The five source categories: Research Outputs, Training and Capacity Building, Product Development, Recognition and Reputation, Society Impact and Inclusion.';

comment on table kpi.indicator_definition is
    'KPI inventory (framework 4.1). One row per metric, reused at project, program and institutional level so unit and aggregation method cannot drift between levels.';
comment on column kpi.indicator_definition.parent_indicator_id is
    'Set on sub-indicators such as KPI 4a, which are derived from their parent''s disaggregation rather than reported separately.';
comment on column kpi.indicator_definition.definition_text is 'The formal "what counts" wording.';
comment on column kpi.indicator_definition.numerator_text is 'Narrative definition of the numerator (framework 4.1).';
comment on column kpi.indicator_definition.denominator_text is 'Narrative definition of the denominator.';
comment on column kpi.indicator_definition.value_type is
    'How the value is interpreted: count, decimal, currency, percentage, ratio or index_score.';
comment on column kpi.indicator_definition.aggregation_method is
    'How children combine into a parent. Framework section 11 methods plus the ordinary statistical ones.';
comment on column kpi.indicator_definition.distinct_entity_type is
    'Which kind of registry entity is de-duplicated. Required when aggregation_method is distinct_count, forbidden otherwise.';
comment on column kpi.indicator_definition.direction is
    'Whether increase, decrease or maintain is good. Drives achievement scoring.';
comment on column kpi.indicator_definition.is_cumulative is
    'True when the KPI accumulates across time. Modelled separately from aggregation_method because it describes accumulation across periods, not how children combine into a parent.';
comment on column kpi.indicator_definition.is_indexed is
    'True for the indexed 2025 source figures (framework 4.2), so a dashboard never presents them as raw counts.';
comment on column kpi.indicator_definition.index_basis_note is 'What the indexed figure is indexed against, where known.';
comment on column kpi.indicator_definition.requires_evidence is
    'When true, an observation must carry evidence before it can be validated (framework 13.1).';
comment on column kpi.indicator_definition.max_level is
    'Highest level the indicator may be used at. The org_level enum is ordered institution < program < project, so a cap of program forbids institutional use.';
comment on column kpi.indicator_definition.definition_status is
    'draft until the Program and MELIA teams validate the definition and calculation rule. Everything loaded by 06_seed_catalogue.sql is draft.';

comment on table kpi.indicator_dimension is
    'Disaggregation contract for an indicator. Required axes are enforced on observation insert (see 03_results.sql).';
comment on column kpi.indicator_dimension.is_required is
    'Required axes must appear on every observation; optional axes may appear and are still grouped by.';

-- =============================================================================
-- The three KPI levels
-- =============================================================================

comment on table kpi.project_indicator is
    'Level 3. A KPI as tracked by one project, optionally scoped to a work package.';
comment on column kpi.project_indicator.local_name is 'The project''s own wording, e.g. "Partners trained - Component A".';
comment on column kpi.project_indicator.data_source is
    'Where values come from: activity rollup, direct entry, an external system, or calculated.';
comment on column kpi.project_indicator.baseline_value is 'Starting value the project measures change against.';

comment on table kpi.program_kpi is 'Level 2. A KPI as reported by one program.';
comment on column kpi.program_kpi.scorecard_weight is
    'Relative importance within the program scorecard. Used for weighted achievement reporting, not for the rollup arithmetic.';

comment on table kpi.institution_kpi is 'Level 1. A KPI as reported institution-wide.';
comment on column kpi.institution_kpi.strategic_objective is 'The strategy this KPI serves.';
comment on column kpi.institution_kpi.scorecard_weight is
    'Relative importance in the institutional scorecard; drives weighted category achievement.';

-- =============================================================================
-- The KPI Mapping Table
-- =============================================================================

comment on table kpi.project_indicator_contribution is
    'KPI Mapping Table, project to program (framework 10.1). Many-to-many: one project indicator can feed several program KPIs. Rows are versioned, never overwritten, so historical figures stay reproducible.';
comment on column kpi.project_indicator_contribution.contribution_factor is
    'Unit conversion or attribution share applied to the child numerator. A trigger forbids anything other than 1 for ratio and percentage indicators, where scaling a numerator without its denominator would change the ratio.';
comment on column kpi.project_indicator_contribution.weight is
    'Static weight used only when the parent aggregates by weighted_average. Data-driven weights live on the observation instead.';
comment on column kpi.project_indicator_contribution.effective_from is 'First date the mapping applies.';
comment on column kpi.project_indicator_contribution.effective_to is 'Last date the mapping applies; null means open-ended.';
comment on column kpi.project_indicator_contribution.mapping_status is
    'draft, validated or retired. Only validated mappings feed published figures.';

comment on table kpi.program_kpi_contribution is
    'KPI Mapping Table, program to institution. Same versioning rules as the project-to-program mapping.';
comment on column kpi.program_kpi_contribution.contribution_factor is
    'Unit conversion or attribution share; must be 1 for ratio and percentage indicators.';
comment on column kpi.program_kpi_contribution.weight is 'Static weight for weighted_average parents.';
comment on column kpi.program_kpi_contribution.mapping_status is
    'draft, validated or retired. Only validated mappings feed published figures.';

-- =============================================================================
-- Targets
-- =============================================================================

comment on table kpi.project_indicator_target is
    'Targets per project indicator, period and disaggregation slice. Separate tables per level rather than one polymorphic table, so the foreign keys are real.';
comment on table kpi.program_kpi_target is 'Targets per program KPI, period and disaggregation slice.';
comment on table kpi.institution_kpi_target is 'Targets per institutional KPI, period and disaggregation slice.';

comment on column kpi.project_indicator_target.disaggregation_key is
    'Empty string is the overall target; a non-empty key targets one slice.';
comment on column kpi.program_kpi_target.disaggregation_key is
    'Empty string is the overall target; a non-empty key targets one slice.';
comment on column kpi.institution_kpi_target.disaggregation_key is
    'Empty string is the overall target; a non-empty key targets one slice.';
comment on column kpi.project_indicator_target.cumulative_target is 'Life-of-project target, where one is set.';
comment on column kpi.program_kpi_target.cumulative_target is 'Multi-year cumulative target, where one is set.';
comment on column kpi.institution_kpi_target.cumulative_target is 'Multi-year cumulative target, where one is set.';

comment on table kpi.performance_band is
    'Traffic-light thresholds (framework section 14). Bands are matched on achievement against target, so a KPI with no target has no band.';
comment on column kpi.performance_band.min_achievement is 'Inclusive lower bound, as a percentage of target.';
comment on column kpi.performance_band.max_achievement is 'Exclusive upper bound, as a percentage of target.';

-- =============================================================================
-- Activities and results
-- =============================================================================

comment on table kpi.activity is
    'Step 1 of the result chain: work implemented by a project, with the context it happened in.';
comment on column kpi.activity.planned_start is 'Planned start; compared against actuals for delivery reporting.';
comment on column kpi.activity.actual_start is 'Actual start. A trigger requires activity dates to fall inside the project dates (framework 13.1).';
comment on column kpi.activity.responsible is 'Person or team accountable for delivery.';

comment on table kpi.activity_partner is 'Partner organisations involved in an activity.';

comment on table kpi.activity_result is
    'Step 2: the narrative and evidence envelope for one activity in one reporting period. The numbers themselves live in observation, so one reported result can feed several indicators and slices.';
comment on column kpi.activity_result.result_date is 'Date the result was achieved, not the date it was entered.';
comment on column kpi.activity_result.status is
    'Approval state. Only validated results contribute to published figures.';
comment on column kpi.activity_result.validated_by is 'Who approved it. Required once status is validated or rejected.';

comment on table kpi.evidence is
    'Supporting documents for a result or an observation: DOIs, thesis records, release gazettes, attendance sheets.';
comment on column kpi.evidence.uri is 'Object-store key, URL or DOI.';
comment on column kpi.evidence.evidence_type is 'What kind of proof this is, e.g. DOI, gazette, attendance_sheet.';

-- =============================================================================
-- Countable-entity registry
-- =============================================================================

comment on table kpi.entity is
    'Registry of the things that must not be double counted: students, partners, ARIs, publications, theses, varieties, innovations, engagement events, proposals. Eight of the twenty KPIs aggregate by COUNT(DISTINCT) against this table, which is impossible from a reported total alone.';
comment on column kpi.entity.entity_type is 'What kind of thing this is; must match the indicator''s distinct_entity_type.';
comment on column kpi.entity.external_ref is
    'Authoritative external identifier where one exists: ORCID, DOI, ROR, gazette number, student registration.';
comment on column kpi.entity.external_ref_system is 'Which register external_ref belongs to.';
comment on column kpi.entity.canonical_key is
    'Generated normalised form of display_name, used for fuzzy duplicate detection before a distinct count runs.';
comment on column kpi.entity.is_personal_data is
    'Marks records holding personal data, so role-based access can mask them (framework 7.2, 18).';
comment on column kpi.entity.merged_into_id is
    'Points at the surviving record when two rows turn out to be the same real-world entity. Every distinct count follows this pointer; records are merged, never deleted, so the audit trail survives. Merge chains are rejected.';
comment on column kpi.entity.attributes is 'Free-form additional properties carried from the source system.';

comment on table kpi.entity_duplicate_candidate is
    'Suspected duplicates awaiting a data steward decision, raised before distinct-count aggregation runs (framework 13.1).';
comment on column kpi.entity_duplicate_candidate.match_score is 'Confidence between 0 and 1.';
comment on column kpi.entity_duplicate_candidate.match_method is 'How the candidate was found: exact_external_ref, canonical_key, trigram.';

-- =============================================================================
-- Observations — the single grain
-- =============================================================================

comment on table kpi.observation is
    'Step 3: one measured value for one project indicator, period and disaggregation slice. This is the single grain every rollup reads from. A null activity_result_id means direct entry, a survey or an import; non-null means it came from a recorded activity.';
comment on column kpi.observation.activity_result_id is
    'The activity result this value came from. Null for direct entry, survey or platform import.';
comment on column kpi.observation.observed_on is 'When the value was measured; drives latest-status aggregation.';
comment on column kpi.observation.numerator is
    'The measured quantity. For ratio and percentage indicators it is the numerator only; for distinct counts it must equal the number of distinct entities listed in observation_entity, which a deferred trigger enforces.';
comment on column kpi.observation.denominator is
    'Populated only for ratio and percentage indicators, and required for them. Carrying it to every level is what lets each level recombine the parts and divide once, instead of averaging percentages.';
comment on column kpi.observation.conversion_factor is
    'Applied when the raw result is recorded in a different unit, or when only part of it counts toward this indicator.';
comment on column kpi.observation.weight is
    'Data-driven weight for weighted_average indicators, e.g. trial or plot count for genetic gain. It accumulates upward, so the weighting survives above project level rather than degrading into a simple average.';
comment on column kpi.observation.disaggregation_key is
    'Denormalised fingerprint of observation_category, maintained by trigger. Empty string means no disaggregation. Lets every rollup group by a single column.';
comment on column kpi.observation.status is
    'Approval state. Only validated observations with no open blocking data-quality flag reach a published figure.';
comment on column kpi.observation.source_system is 'Which platform the value arrived from.';
comment on column kpi.observation.source_record_ref is 'Key in the originating platform, for round-trip traceability.';
comment on column kpi.observation.country_id is 'Drill-down context, inherited from the activity when not stated.';
comment on column kpi.observation.commodity_id is 'Drill-down context, inherited from the activity when not stated.';
comment on column kpi.observation.partner_id is 'Drill-down context: the partner this value relates to, where relevant.';

comment on table kpi.observation_category is
    'The disaggregation slice of an observation: one row per axis. A composite foreign key proves the category belongs to the dimension it is filed under.';

comment on table kpi.observation_entity is
    'Names the entities behind a count so program and institutional rollups can COUNT(DISTINCT) instead of summing project totals.';

-- =============================================================================
-- Snapshots
-- =============================================================================

comment on table kpi.kpi_snapshot is
    'Frozen copy of computed values for one reporting period across all three levels. The rollup views always reflect current data; a snapshot preserves what was actually reported, so a board pack still reconciles after a project restates its figures. Earlier runs for a period are marked superseded rather than deleted.';
comment on column kpi.kpi_snapshot.org_level is 'Which level this row belongs to; exactly one of the three KPI foreign keys is set.';
comment on column kpi.kpi_snapshot.value is 'The derived value at snapshot time.';
comment on column kpi.kpi_snapshot.achievement_pct is 'Achievement against target at snapshot time, respecting indicator direction.';
comment on column kpi.kpi_snapshot.contributor_count is 'Contributing projects or programs, depending on level.';
comment on column kpi.kpi_snapshot.status is 'superseded once a later snapshot replaces it.';

-- =============================================================================
-- Ingestion and staging
-- =============================================================================

comment on table kpi.ingestion_batch is
    'One extraction run from a source platform (architecture layer 3).';
comment on column kpi.ingestion_batch.integration_mode is 'api, file_etl or db_replica — framework section 12''s three patterns.';
comment on column kpi.ingestion_batch.source_reference is 'File name, API cursor or export id; also serves as the incremental high-water mark.';
comment on column kpi.ingestion_batch.accepted_count is 'Records that passed validation and became observations.';
comment on column kpi.ingestion_batch.flagged_count is 'Records held by a data-quality rule.';

comment on table kpi.staging_record is
    'Raw extracted data retained for traceability before transformation (architecture layer 4). Records that fail validation stop here and never become observations, so a published figure can always be traced back to the bytes the source platform actually sent.';
comment on column kpi.staging_record.payload is 'The untransformed submission body, exactly as received.';
comment on column kpi.staging_record.observation_id is 'The observation this raw record eventually became, if any.';
comment on column kpi.staging_record.process_status is 'pending, transformed, flagged, rejected or skipped.';

-- =============================================================================
-- Data quality
-- =============================================================================

comment on table kpi.dq_rule is
    'Validation rules as configuration rather than code, so MELIA and data staff can add checks without a deployment. Each rule names one of the framework''s seven quality dimensions.';
comment on column kpi.dq_rule.dimension is
    'One of completeness, accuracy, consistency, timeliness, validity, uniqueness, integrity.';
comment on column kpi.dq_rule.blocks_publication is
    'When true, an open flag withholds the value from published figures. When false the value still publishes and the flag is advisory.';
comment on column kpi.dq_rule.check_expression is 'SQL predicate evaluated by the validation job; text because rules are authored at runtime.';
comment on column kpi.dq_rule.indicator_definition_id is 'Narrows the rule to one indicator; null applies it to all.';

comment on table kpi.dq_flag is
    'Validation failures. Records are flagged and excluded from published figures, never deleted (framework 13). Exactly one target column is set, identifying the record the flag applies to.';
comment on column kpi.dq_flag.status is 'open, under_review, resolved or waived. Resolving a flag restores the value with no re-entry.';
comment on column kpi.dq_flag.detail is 'What specifically failed, for the person who has to fix it.';

-- =============================================================================
-- Access control and audit
-- =============================================================================

comment on table kpi.app_user is 'Dashboard users (framework section 15).';
comment on column kpi.app_user.external_idp_ref is 'Subject identifier from the identity provider, for single sign-on.';

comment on table kpi.app_role is 'Named roles: executive, program leader, project manager, MELIA, data admin, viewer.';
comment on column kpi.app_role.can_view_personal_data is
    'Whether the role may see unmasked entity records marked is_personal_data.';

comment on table kpi.app_user_role is 'Role grants (many-to-many).';

comment on table kpi.app_user_scope is
    'What slice of the hierarchy a user may see. At most one of the three foreign keys is set; a row with all three null means institution-wide access.';

comment on table kpi.audit_log is
    'Change history for data and KPI recalculations (framework 16, 18). Attached by trigger to observations, both mapping tables and indicator definitions; snapshots log here too.';
comment on column kpi.audit_log.action is 'insert, update, delete, recalculate or snapshot.';
comment on column kpi.audit_log.record_id is 'Primary key of the affected row, as text.';
comment on column kpi.audit_log.old_value is 'Row image before the change.';
comment on column kpi.audit_log.new_value is 'Row image after the change.';

-- =============================================================================
-- Alerts
-- =============================================================================

comment on table kpi.alert_rule is
    'Alert definitions for the five types in framework section 17: performance, reporting, data quality, target and stale data.';
comment on column kpi.alert_rule.threshold_value is 'Achievement threshold, for performance and target alerts.';
comment on column kpi.alert_rule.stale_after_days is 'Days without a new observation before a stale-data alert fires.';

comment on table kpi.alert is
    'Raised alerts. Exactly one KPI foreign key is set, identifying the level the alert concerns.';

-- =============================================================================
-- Source form mapping
-- =============================================================================

comment on table kpi.source_system is
    'A platform data arrives from, e.g. an ODK Central server.';
comment on column kpi.source_system.platform is 'odk_central, excel, rest_api and so on.';
comment on column kpi.source_system.integration_mode is 'api, file_etl or db_replica.';

comment on table kpi.source_form is
    'One row per form VERSION. Mappings bind to a version, so republishing a form can never silently change what a historical figure meant.';
comment on column kpi.source_form.external_project_ref is 'The source platform''s own project id, not kpi.project.';
comment on column kpi.source_form.external_form_id is 'The form identifier in the source platform, e.g. an ODK xmlFormId.';
comment on column kpi.source_form.project_id is 'Owning project, or null for an institution-wide module.';

comment on table kpi.source_form_field is
    'Fields discovered from a published form definition, so mappings can be validated against the real schema rather than a path typed from memory.';
comment on column kpi.source_form_field.path is 'Path within the submission, e.g. training/attendees/sex.';
comment on column kpi.source_form_field.is_repeat is 'True for repeat groups, which are the rows a roster-based mapping counts.';

comment on table kpi.source_mapping is
    'Binds one form version to one project indicator. Maps modules, not questions — see docs/ODK-Central-Integration.md. Versioned the same way as the KPI Mapping Table above it.';
comment on column kpi.source_mapping.value_mode is
    'How submission rows become a numerator: count_rows, distinct_entity, sum_field, value_field or ratio_fields. A check constraint enforces that each mode carries the paths it needs.';
comment on column kpi.source_mapping.repeat_path is
    'The repeat group whose rows are counted. Null means the submission itself is the single row.';
comment on column kpi.source_mapping.value_path is 'Where the number comes from, for sum_field, value_field and ratio_fields.';
comment on column kpi.source_mapping.denominator_path is 'Where the denominator comes from, for ratio_fields.';
comment on column kpi.source_mapping.weight_path is 'Where the weight comes from, for weighted-average indicators.';
comment on column kpi.source_mapping.entity_ref_path is 'Stable identifier on each row, resolved against entity.external_ref.';
comment on column kpi.source_mapping.entity_label_path is 'Display name, used only when registering a previously unseen identifier.';
comment on column kpi.source_mapping.row_filter is
    'Optional predicate applied to rows before counting, e.g. only attendees who completed the course.';
comment on column kpi.source_mapping.observed_on_path is 'Where the measurement date comes from.';

comment on table kpi.source_mapping_dimension is
    'How a form answer becomes a disaggregation category, so a form that codes sex differently from the catalogue still lands in the right slice without being edited.';
comment on column kpi.source_mapping_dimension.value_map is
    'Answer value to dimension_category.code, e.g. {"female":"F","1":"F"}.';
comment on column kpi.source_mapping_dimension.fallback_category_id is
    'Category used when the answer is blank or unrecognised. Null means the row is flagged rather than silently bucketed.';

comment on table kpi.source_submission is
    'One submission from a source platform. Keyed on the platform''s stable instance id, which makes re-ingestion idempotent: pulling the same submission twice updates the same observation instead of double counting it.';
comment on column kpi.source_submission.instance_id is 'The platform''s stable submission identifier, e.g. an ODK instanceID.';
comment on column kpi.source_submission.review_state is
    'The source platform''s own review state, mapped onto observation.status during transformation.';

comment on table kpi.source_submission_observation is
    'Which observations a submission produced. One submission commonly produces several: one per indicator, per disaggregation slice.';

-- =============================================================================
-- Recurring columns
--
-- These patterns repeat across tables. The generated reference describes the
-- pattern once under Conventions; the comments below cover the cases where the
-- column carries meaning beyond the pattern.
-- =============================================================================

comment on column kpi.indicator_definition.unit is
    'Unit of measurement, e.g. papers, partners, %. Declared once in the catalogue so it cannot differ between levels.';

comment on column kpi.project_indicator.responsible is 'Person accountable for reporting this indicator.';
comment on column kpi.program_kpi.responsible is 'Person accountable for reporting this KPI.';
comment on column kpi.institution_kpi.responsible is 'Person accountable for reporting this KPI.';

comment on column kpi.program_kpi.local_name is 'The program''s own wording for the KPI, where it differs from the catalogue.';
comment on column kpi.institution_kpi.local_name is 'The institution''s own wording for the KPI, where it differs from the catalogue.';

comment on column kpi.program_kpi.baseline_value is 'Starting value the program measures change against.';
comment on column kpi.institution_kpi.baseline_value is 'Starting value the institution measures change against.';
comment on column kpi.project_indicator.baseline_date is 'When the baseline was measured.';
comment on column kpi.program_kpi.baseline_date is 'When the baseline was measured.';
comment on column kpi.institution_kpi.baseline_date is 'When the baseline was measured.';

comment on column kpi.project_indicator_target.target_value is 'Target for this period. Achievement is scored against it respecting the indicator''s direction.';
comment on column kpi.program_kpi_target.target_value is 'Target for this period, scored respecting the indicator''s direction.';
comment on column kpi.institution_kpi_target.target_value is 'Target for this period, scored respecting the indicator''s direction.';

comment on column kpi.dq_flag.severity is 'Copied from the rule at detection time, so re-grading a rule does not rewrite history.';
comment on column kpi.alert.severity is 'How urgently the alert needs attention.';
comment on column kpi.dq_rule.severity is 'Default severity applied to flags this rule raises.';

comment on column kpi.program_kpi_contribution.effective_from is 'First date the mapping applies.';
comment on column kpi.program_kpi_contribution.effective_to is 'Last date the mapping applies; null means open-ended.';
comment on column kpi.source_mapping.effective_from is 'First date the mapping applies.';
comment on column kpi.source_mapping.effective_to is 'Last date the mapping applies; null means open-ended.';

comment on column kpi.ingestion_batch.error_text is 'Failure detail when the batch itself did not complete.';
comment on column kpi.staging_record.error_text is 'Why this record could not be transformed.';
comment on column kpi.staging_record.processed_at is 'When the transform last ran against this record.';
comment on column kpi.source_submission.processed_at is 'When this submission was last turned into observations.';
comment on column kpi.source_submission.submitter is 'Who submitted the form, as reported by the source platform.';
comment on column kpi.source_submission.submitted_at is 'When the submission was made in the field, not when it was ingested.';

comment on column kpi.audit_log.table_name is 'Schema-qualified table the change applied to.';
comment on column kpi.audit_log.actor is 'Database role that made the change, when no application user is known.';
comment on column kpi.audit_log.reason is 'Free-text justification, used by snapshot and recalculation entries.';

comment on column kpi.app_user.username is 'Login name; the natural key.';

-- =============================================================================
-- Functions and trigger functions
-- =============================================================================

comment on function kpi.compute_value(numeric, numeric, kpi.value_type) is
    'Derives a displayable value from a numerator and optional denominator. Additive indicators use the numerator alone; ratios divide; percentages divide and scale to 0-100. Returns null on a zero denominator rather than raising.';

comment on function kpi.achievement_pct(numeric, numeric, kpi.direction) is
    'Achievement against target as a percentage, respecting indicator direction: for a decrease-is-good KPI, coming in under target scores above 100.';

comment on function kpi.canonical_entity_id(bigint, bigint) is
    'Resolves an entity to its surviving record, following a merge pointer. Every distinct count goes through this so a merged duplicate can never inflate a figure.';

comment on function kpi.assert_observation_valid(bigint) is
    'Enforces an observation''s contract with its indicator: required disaggregation present, no undeclared axes, denominator present exactly when the indicator is a ratio or percentage, percentages within range, counts non-negative, and a distinct count''s numerator matching the entities actually listed. Raises rather than warns.';

comment on function kpi.refresh_disaggregation_key() is
    'Keeps observation.disaggregation_key in sync with observation_category, so every rollup can group by a single column instead of joining the bridge table.';

comment on function kpi.set_updated_at() is
    'Shared audit trigger: stamps updated_at on modification.';

comment on function kpi.tg_activity_within_project() is
    'Rejects activities whose actual dates fall outside the implementing project, or that belong to a cancelled or not-yet-started project (framework 13.1).';

comment on function kpi.tg_assert_observation_valid() is
    'Deferred constraint trigger on observation; calls assert_observation_valid at commit so parent and child rows can be inserted in any order.';

comment on function kpi.tg_assert_observation_child_valid() is
    'Deferred constraint trigger on observation_category and observation_entity; re-checks the parent observation''s contract when its child rows change.';

comment on function kpi.tg_audit_row() is
    'Generic row-level audit trigger. Writes before and after row images to audit_log. Attached selectively, to keep write volume proportionate.';

comment on function kpi.tg_check_max_level() is
    'Honours indicator_definition.max_level. Takes the level as a trigger argument and rejects a KPI created above the catalogue''s declared ceiling.';

comment on function kpi.tg_entity_no_merge_chain() is
    'Rejects merge chains and merging a record that is itself a merge target, so resolving an entity is always a single hop and never order-dependent.';

comment on function kpi.tg_observation_inherit_context() is
    'Fills country, location and commodity from the originating activity when an observation does not state them, so drill-down works without re-keying context.';

comment on function kpi.tg_reject_closed_period() is
    'Rejects observations written into a closed reporting period. Snapshots are still permitted.';

comment on function kpi.tg_validate_project_contribution() is
    'Validates a project-to-program mapping: the project must belong to the target program, both sides must share one indicator definition, and ratio or percentage indicators may not carry an attribution factor.';

comment on function kpi.tg_validate_program_contribution() is
    'Validates a program-to-institution mapping, with the same rules as the project-to-program case one level down.';

-- =============================================================================
-- Views
--
-- A handful already carry comments from the files that define them; these fill
-- in the rest so the generated reference describes every view.
-- =============================================================================

comment on view kpi.v_project_mapping is
    'Currently validated project-to-program mappings. Draft and retired rows are excluded, so nothing unapproved reaches a published figure.';
comment on view kpi.v_program_mapping is
    'Currently validated program-to-institution mappings.';

comment on view kpi.v_project_indicator_entity is
    'One row per distinct entity reaching a project indicator, per period and slice. Long rather than pre-aggregated, so the same rows serve both the per-slice figure and the overall total.';
comment on view kpi.v_program_kpi_entity is
    'Distinct entities reaching a program KPI. A delivery partner trained by three projects in the program appears once.';

comment on view kpi.v_project_indicator_kpi is
    'Step 5 with the derived value, target and achievement attached; the reporting-friendly form of v_project_indicator_value.';
comment on view kpi.v_program_kpi_scorecard is
    'Program KPI values per disaggregation slice, with target and achievement.';
comment on view kpi.v_institution_kpi_value is
    'Step 7: program KPIs aggregated to the institution, per period and slice. Distinct-count indicators are recounted from the entity reach view rather than summed.';
comment on view kpi.v_institution_kpi_scorecard is
    'Institutional KPI values per disaggregation slice, with target, achievement and traffic-light band.';

comment on view kpi.v_program_kpi_total is
    'Program KPI combined across disaggregation slices. Additive and ratio indicators combine their slices; distinct counts are recounted from entities, since one entity can legitimately appear in more than one slice.';
comment on view kpi.v_institution_kpi_total is
    'Institutional KPI combined across disaggregation slices, with the same distinct-count exception.';

comment on view kpi.v_program_kpi_headline is
    'The whole-KPI program figure with target and traffic light. Reads from the totals rather than the sliced views, so KPIs that are always disaggregated still appear.';
comment on view kpi.v_institution_kpi_headline is
    'The whole-KPI institutional figure with target and traffic light. This is what a scorecard should read.';

comment on view kpi.v_institution_female_share is
    'Derives the "a" sub-indicators (KPI 4a, 5a, 6a, 7a) from their parent''s own sex disaggregation, so the share and the total can never disagree.';
comment on view kpi.v_institution_kpi_cumulative is
    'Running totals for cumulative indicators. Adds each period''s increment to the prior cumulative value rather than re-summing history.';

comment on view kpi.v_kpi_fact is
    'Observation-grain fact view with every drill-down dimension attached (framework 9.2 star schema). Slice this by country, commodity or partner; the KPI views are the official aggregates.';
comment on view kpi.v_kpi_lineage is
    'Traces a published figure back to the observations, activities and evidence that produced it, including the contribution factors applied at each level.';

comment on view kpi.v_institution_scorecard_display is
    'The institutional scorecard laid out for presentation: categories in source order, sub-indicators attached to their parent, values rounded to the indicator''s declared precision.';
comment on view kpi.v_program_category_performance is
    'KPI counts by traffic-light state and average achievement, per category and program.';

comment on view kpi.v_dq_flag_detail is
    'Every data-quality flag with the rule it broke, the record it applies to and whether it withholds a published figure.';
comment on view kpi.v_ingestion_summary is
    'Per-batch ingestion health: how much raw data was staged, transformed, flagged or rejected.';
