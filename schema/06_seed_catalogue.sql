-- =============================================================================
-- 06_seed_catalogue.sql — reference data and the KPI catalogue
--
-- Loads: the institution, the five KPI categories, the 20 KPIs plus their
-- "a" sub-indicators, disaggregation axes, performance bands, DQ rules, and the
-- 2025-2030 reporting calendar.
--
-- Every KPI is loaded with definition_status = 'draft'. The framework is
-- explicit that the source CSV supplied only category, ID, name and a 2025
-- figure — definitions, numerators/denominators, data sources, owners,
-- baselines and targets are all "to be defined/validated by the institution" (section 4.1).
-- The aggregation methods below are the framework's own proposals from section
-- 11.1 and must be confirmed in the business-rule validation workshop before
-- any figure is published.
-- =============================================================================

set search_path = kpi, public;

-- -----------------------------------------------------------------------------
-- Institution
-- -----------------------------------------------------------------------------

insert into kpi.country (iso3166_alpha2, iso3166_alpha3, name, region) values
    ('NG', 'NGA', 'Nigeria',                      'West Africa'),
    ('BJ', 'BEN', 'Benin',                        'West Africa'),
    ('GH', 'GHA', 'Ghana',                        'West Africa'),
    ('CD', 'COD', 'Democratic Republic of Congo', 'Central Africa'),
    ('CM', 'CMR', 'Cameroon',                     'Central Africa'),
    ('KE', 'KEN', 'Kenya',                        'East Africa'),
    ('TZ', 'TZA', 'Tanzania',                     'East Africa'),
    ('UG', 'UGA', 'Uganda',                       'East Africa'),
    ('RW', 'RWA', 'Rwanda',                       'East Africa'),
    ('ZM', 'ZMB', 'Zambia',                       'Southern Africa'),
    ('MW', 'MWI', 'Malawi',                       'Southern Africa'),
    ('MZ', 'MOZ', 'Mozambique',                   'Southern Africa');

insert into kpi.institution (code, name, description, country_id)
select 'INST',
       'Example Research Institute',
       'Placeholder institution at the top of the KPI hierarchy. Replace the code, name and country with your own; nothing else in the schema depends on these values.',
       c.id
from kpi.country c where c.iso3166_alpha2 = 'NG';

insert into kpi.commodity (code, name, crop_group) values
    ('CASSAVA',  'Cassava',   'Roots and tubers'),
    ('YAM',      'Yam',       'Roots and tubers'),
    ('BANANA',   'Banana and plantain', 'Bananas'),
    ('COWPEA',   'Cowpea',    'Grain legumes'),
    ('SOYBEAN',  'Soybean',   'Grain legumes'),
    ('MAIZE',    'Maize',     'Cereals'),
    ('CROSS',    'Cross-commodity', 'Not crop-specific');

-- -----------------------------------------------------------------------------
-- KPI categories (framework section 4)
-- -----------------------------------------------------------------------------

insert into kpi.kpi_category (code, name, sort_order, description) values
    ('RESEARCH_OUTPUTS',   'Research Outputs',              1,
     'Peer-reviewed publication output and research productivity.'),
    ('TRAINING_CAPACITY',  'Training and Capacity Building', 2,
     'Degree students, delivery partners and national scientists trained.'),
    ('PRODUCT_DEVELOPMENT','Product Development',            3,
     'Varieties released, genetic gain, germplasm compliance, innovations scaled.'),
    ('RECOGNITION',        'Recognition and Reputation',     4,
     'Collaborations, awards, invitations and policy engagement.'),
    ('SOCIETY_INCLUSION',  'Society Impact and Inclusion',   5,
     'Gender, youth, climate and nutrition content of approved proposals.');

-- -----------------------------------------------------------------------------
-- Disaggregation axes
--
-- Sex disaggregation is implied for KPIs 4-7 (framework 4.1): each of those has
-- a companion "a" indicator reporting the female share. Modelling sex as a
-- disaggregation axis means the "a" percentage can be derived from the same
-- observations rather than reported separately and risking disagreement.
-- -----------------------------------------------------------------------------

insert into kpi.dimension (code, name, description, sort_order) values
    ('SEX',          'Sex',          'Sex of the person counted.', 1),
    ('AGE_BAND',     'Age band',     'Youth classification for inclusion reporting.', 2),
    ('DEGREE_LEVEL', 'Degree level', 'Level of postgraduate study.', 3),
    ('PARTNER_TYPE', 'Partner type', 'Category of partner organisation.', 4);

insert into kpi.dimension_category (dimension_id, code, label, sort_order)
select d.id, v.code, v.label, v.sort_order
from kpi.dimension d
join (values
    ('SEX', 'F',       'Female',            1),
    ('SEX', 'M',       'Male',              2),
    ('SEX', 'OTHER',   'Other / undisclosed', 3),
    ('AGE_BAND', 'YOUTH',     'Youth (under 35)', 1),
    ('AGE_BAND', 'NON_YOUTH', '35 and over',      2),
    ('DEGREE_LEVEL', 'PHD', 'PhD', 1),
    ('DEGREE_LEVEL', 'MSC', 'MSc', 2),
    ('PARTNER_TYPE', 'ARI',     'Advanced Research Institute', 1),
    ('PARTNER_TYPE', 'NARS',    'National Agricultural Research System', 2),
    ('PARTNER_TYPE', 'SCALING', 'Scaling partner', 3),
    ('PARTNER_TYPE', 'PRIVATE', 'Private sector', 4)
) as v(dim_code, code, label, sort_order) on v.dim_code = d.code;

-- -----------------------------------------------------------------------------
-- The 20 KPIs (framework sections 4 and 11.1)
--
-- aggregation_method values come from the framework's proposed methods table;
-- every one is marked draft pending validation.
-- -----------------------------------------------------------------------------

insert into kpi.indicator_definition (
    code, kpi_category_id, name, value_type, unit, aggregation_method,
    distinct_entity_type, direction, decimal_places, is_indexed, is_cumulative,
    requires_evidence, index_basis_note, data_source_note)
select v.code, cat.id, v.name, v.value_type::kpi.value_type, v.unit,
       v.method::kpi.aggregation_method, v.entity_type::kpi.entity_type,
       'increase'::kpi.direction, v.decimals, v.is_indexed, v.is_cumulative,
       v.requires_evidence, v.index_note, 'To be defined/validated by the institution'
from (values
    -- Research Outputs
    ('KPI_1',  'RESEARCH_OUTPUTS', 'Number of papers published in Thomson-indexed journals',
        'count', 'papers', 'sum', null, 2, true, false, true,
        '2025 source value 2.4950 is an indexed figure, not a raw count.'),
    ('KPI_2',  'RESEARCH_OUTPUTS', 'Number of papers published in Thomson-indexed journals per Internationally Recruited Staff (IRS)',
        'ratio', 'papers per IRS', 'ratio', null, 3, false, false, false,
        'No 2025 value supplied in the source file — candidate for a data-quality alert.'),
    ('KPI_3',  'RESEARCH_OUTPUTS', 'Number of Thomson-indexed papers published with an impact factor greater than 10',
        'count', 'papers', 'sum', null, 3, true, false, true,
        '2025 source value 0.0690 is an indexed figure. Subset filter: impact factor > 10.'),

    -- Training and Capacity Building
    ('KPI_4',  'TRAINING_CAPACITY', 'Number of PhD and MSc students enrolled',
        'count', 'students', 'distinct_count', 'person', 2, true, true, false,
        'Deduplicated across projects: a student enrolled under more than one project counts once.'),
    ('KPI_4A', 'TRAINING_CAPACITY', 'Percentage of PhD and MSc students enrolled who are female',
        'percentage', '%', 'ratio', null, 1, false, false, false,
        'Derived from the SEX disaggregation of KPI 4.'),
    ('KPI_5',  'TRAINING_CAPACITY', 'Number of PhD and MSc theses accepted',
        'count', 'theses', 'distinct_count', 'thesis', 2, true, true, true,
        'Thesis record required as evidence.'),
    ('KPI_5A', 'TRAINING_CAPACITY', 'Percentage of PhD and MSc theses accepted that are by female students',
        'percentage', '%', 'ratio', null, 1, false, false, false,
        'Derived from the SEX disaggregation of KPI 5.'),
    ('KPI_6',  'TRAINING_CAPACITY', 'Number of delivery partners trained',
        'count', 'partners', 'distinct_count', 'organization', 2, true, false, false,
        'A delivery partner may work with several projects; counted once.'),
    ('KPI_6A', 'TRAINING_CAPACITY', 'Percentage of delivery partners trained who are female',
        'percentage', '%', 'ratio', null, 1, false, false, false,
        'Derived from the SEX disaggregation of KPI 6.'),
    ('KPI_7',  'TRAINING_CAPACITY', 'Number of national scientists who attended training courses',
        'count', 'scientists', 'distinct_count', 'person', 2, true, false, false,
        'Deduplicated across projects and courses.'),
    ('KPI_7A', 'TRAINING_CAPACITY', 'Percentage of national scientists who attended training courses who are female',
        'percentage', '%', 'ratio', null, 1, false, false, false,
        'Derived from the SEX disaggregation of KPI 7.'),

    -- Product Development
    ('KPI_8',  'PRODUCT_DEVELOPMENT', 'Number of varieties released',
        'count', 'varieties', 'distinct_count', 'variety', 2, true, true, true,
        'Deduplicated by variety across programs. Release gazette required as evidence.'),
    ('KPI_9',  'PRODUCT_DEVELOPMENT', 'Average (across crops) percentage yield-related genetic gain',
        'percentage', '%', 'weighted_average', null, 2, false, false, false,
        'Weighted by trial/plot count or crop area — weighting basis to be confirmed by the institution.'),
    ('KPI_10', 'PRODUCT_DEVELOPMENT', 'Crop Trust performance compliance rate',
        'percentage', '%', 'latest', null, 1, false, false, true,
        'Compliance is a current status, not an accumulation: latest validated observation wins.'),
    ('KPI_11', 'PRODUCT_DEVELOPMENT', 'Number of institutional innovations incorporated into the regional technology e-Catalogue',
        'count', 'innovations', 'distinct_count', 'innovation', 2, true, true, false,
        'An innovation is catalogued once.'),
    ('KPI_12', 'PRODUCT_DEVELOPMENT', 'Number of institutional innovations taken on by scaling partners',
        'count', 'innovations', 'distinct_count', 'innovation', 2, true, false, false,
        'Deduplicated by innovation.'),

    -- Recognition and Reputation
    ('KPI_13', 'RECOGNITION', 'Number of collaborations with Advanced Research Institutes (ARIs)',
        'count', 'collaborations', 'distinct_count', 'organization', 2, true, false, false,
        'An ARI collaboration counts once even when it spans several projects.'),
    ('KPI_14', 'RECOGNITION', 'Number of active collaborations with scaling partners',
        'count', 'collaborations', 'distinct_count', 'organization', 2, true, false, false,
        'Deduplicated by partner.'),
    ('KPI_15', 'RECOGNITION', 'Number of awards to institutional staff or project teams',
        'count', 'awards', 'sum', null, 3, true, false, true,
        '2025 source value 0.0920 is an indexed figure.'),
    ('KPI_16', 'RECOGNITION', 'Number of invitations for presentations or seminars',
        'count', 'invitations', 'sum', null, 2, true, false, false,
        '2025 source value 0.2100 is an indexed figure.'),
    ('KPI_17', 'RECOGNITION', 'Number of direct engagements with senior policy makers',
        'count', 'engagements', 'distinct_count', 'engagement_event', 2, true, false, false,
        'Deduplicated by engagement event.'),

    -- Society Impact and Inclusion
    ('KPI_18', 'SOCIETY_INCLUSION', 'Percentage of approved proposals with gender/youth/social inclusion components',
        'percentage', '%', 'ratio', null, 1, false, false, false,
        'Numerator and denominator counted across all approved proposals; never summed as a percentage.'),
    ('KPI_19', 'SOCIETY_INCLUSION', 'Percentage of approved proposals with inclusion of adaptation/mitigation activities',
        'percentage', '%', 'ratio', null, 1, false, false, false,
        'Numerator and denominator counted across all approved proposals.'),
    ('KPI_20', 'SOCIETY_INCLUSION', 'Percentage of approved proposals with inclusion of nutrition and health activities',
        'percentage', '%', 'ratio', null, 1, false, false, false,
        'Numerator and denominator counted across all approved proposals.')
) as v(code, cat_code, name, value_type, unit, method, entity_type, decimals,
       is_indexed, is_cumulative, requires_evidence, index_note)
join kpi.kpi_category cat on cat.code = v.cat_code;

-- Attach the "a" sub-indicators to their parents (framework section 4).
update kpi.indicator_definition child
   set parent_indicator_id = parent.id
  from kpi.indicator_definition parent
 where child.code = parent.code || 'A';

-- Sex disaggregation is required for KPIs 4-7 so the "a" percentages can be
-- derived from the same observations rather than reported independently.
insert into kpi.indicator_dimension (indicator_definition_id, dimension_id, is_required)
select idef.id, d.id, true
from kpi.indicator_definition idef
cross join kpi.dimension d
where idef.code in ('KPI_4', 'KPI_5', 'KPI_6', 'KPI_7')
  and d.code = 'SEX';

-- Degree level is a useful optional split for the student indicators.
insert into kpi.indicator_dimension (indicator_definition_id, dimension_id, is_required)
select idef.id, d.id, false
from kpi.indicator_definition idef
cross join kpi.dimension d
where idef.code in ('KPI_4', 'KPI_5')
  and d.code = 'DEGREE_LEVEL';

-- -----------------------------------------------------------------------------
-- Reporting calendar 2023-2030
--
-- Runs from 2023 so the three historical years carry comparable trend data, and
-- out to 2030, the target horizon in the source file.
-- -----------------------------------------------------------------------------

insert into kpi.reporting_period (code, name, period_type, fiscal_year, start_date, end_date)
select 'FY' || y, 'Financial Year ' || y, 'year', y,
       make_date(y, 1, 1), make_date(y, 12, 31)
from generate_series(2023, 2030) as y;

insert into kpi.reporting_period (code, name, period_type, fiscal_year,
                                  start_date, end_date, parent_period_id)
select y || '-Q' || q,
       'Q' || q || ' ' || y,
       'quarter', y,
       make_date(y, (q - 1) * 3 + 1, 1),
       (make_date(y, (q - 1) * 3 + 1, 1) + interval '3 months - 1 day')::date,
       parent.id
from generate_series(2023, 2030) as y
cross join generate_series(1, 4) as q
join kpi.reporting_period parent on parent.code = 'FY' || y;

-- Closed years reject new observations. 06 leaves everything open so demo data
-- can be loaded; 07 closes the historical years once it has finished.


-- -----------------------------------------------------------------------------
-- Traffic-light bands (framework section 14)
-- -----------------------------------------------------------------------------

insert into kpi.performance_band (code, label, min_achievement, max_achievement, colour_hex, sort_order) values
    ('ON_TRACK',  'On track',  90,   null, '#1a7f37', 1),
    ('AT_RISK',   'At risk',   70,   90,   '#bf8700', 2),
    ('OFF_TRACK', 'Off track', null, 70,   '#cf222e', 3);

-- -----------------------------------------------------------------------------
-- Data-quality rules (framework section 13.1)
-- -----------------------------------------------------------------------------

insert into kpi.dq_rule (code, name, dimension, severity, blocks_publication, description) values
    ('REQUIRED_FIELDS',   'Required fields present', 'completeness', 'error', true,
     'KPI, project, period and value must all be present.'),
    ('NEGATIVE_COUNT',    'No negative counts', 'validity', 'error', true,
     'Count-type indicators cannot report a negative value.'),
    ('PCT_RANGE',         'Percentage within range', 'validity', 'error', true,
     'Percentage indicators must fall between 0 and 100.'),
    ('ACTIVITY_IN_PROJECT_DATES', 'Activity within project dates', 'consistency', 'error', true,
     'Activity dates must fall inside the implementing project start and end dates.'),
    ('MAPPING_EFFECTIVE', 'Mapping currently effective', 'integrity', 'error', true,
     'A contribution must map to a validated, currently effective KPI mapping.'),
    ('GEO_CODED',         'Geography uses standard codes', 'validity', 'warning', false,
     'Locations must resolve to ISO 3166 country codes rather than free text.'),
    ('DUPLICATE_ENTITY',  'Possible duplicate entity', 'uniqueness', 'warning', false,
     'Candidate duplicate detected before a distinct-count aggregation is run.'),
    ('EVIDENCE_MISSING',  'Evidence missing', 'integrity', 'error', true,
     'Indicators flagged requires_evidence must carry supporting evidence before validation.'),
    ('STALE_DATA',        'No recent submission', 'timeliness', 'warning', false,
     'No new observation recorded for this indicator within the expected reporting cycle.'),
    ('NO_TARGET',         'Target not supplied', 'completeness', 'warning', false,
     'Target-versus-actual and traffic lights cannot be shown until a target is set.'),
    ('OUTLIER_VALUE',     'Value is a statistical outlier', 'accuracy', 'error', true,
     'Reported value departs from the indicator history by more than the accepted tolerance.'),
    ('UNIT_MISMATCH',     'Value inconsistent with unit', 'accuracy', 'warning', false,
     'Magnitude suggests the value was reported in a different unit from the indicator definition.'),
    ('SEX_CONFLICT',      'Conflicting disaggregation for one entity', 'consistency', 'warning', false,
     'The same person or organisation is reported under different sex categories by different projects.'),
    ('LATE_SUBMISSION',   'Submitted after the reporting deadline', 'timeliness', 'warning', false,
     'Observation recorded well after the reporting period closed.'),
    ('ORPHAN_REFERENCE',  'Reference not resolvable', 'integrity', 'error', true,
     'Incoming record refers to a project, indicator or period that does not exist.');

-- -----------------------------------------------------------------------------
-- Alert rules (framework section 17)
-- -----------------------------------------------------------------------------

insert into kpi.alert_rule (code, name, alert_type, description, threshold_value, stale_after_days) values
    ('UNDERPERFORMING', 'KPI below 70% of target', 'performance',
     'Raised when achievement against target falls below the off-track threshold.', 70, null),
    ('NO_SUBMISSION',   'No submission this period', 'reporting',
     'Raised when a project indicator receives no observation in an open period.', null, null),
    ('DQ_BLOCKING',     'Blocking data-quality flag open', 'data_quality',
     'Raised when an unresolved blocking flag is suppressing a published figure.', null, null),
    ('TARGET_MISSING',  'Target not supplied', 'target',
     'Raised for KPIs with no target for the current period.', null, null),
    ('STALE_90D',       'Stale data', 'stale_data',
     'Raised when the latest observation is older than the reporting cycle allows.', null, 90);

-- -----------------------------------------------------------------------------
-- Access-control roles (framework section 15)
-- -----------------------------------------------------------------------------

insert into kpi.app_role (code, name, can_view_personal_data, description) values
    ('EXEC',           'Executive / Management',  false,
     'Institutional dashboard, all programs, no personal data.'),
    ('PROGRAM_LEADER', 'Program Leader',          false,
     'Full view of their own program and its projects.'),
    ('PROJECT_MANAGER','Project Manager',         true,
     'Data entry and view for their own project.'),
    ('MELIA',          'MELIA / M&E Specialist',  true,
     'Maintains indicator definitions, KPI mappings and data-quality rules.'),
    ('DATA_ADMIN',     'Data / ICT Administrator', true,
     'Manages integrations, staging and reference data.'),
    ('VIEWER',         'Read-only Viewer',        false,
     'Dashboard access without edit rights.');
