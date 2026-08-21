# Mapping ODK Central forms to project-level indicators

How a survey submission collected in the field becomes a validated observation
against a project indicator, and from there a Program and Institutional KPI.

> **A note on the source framework.** The *Program KPI Dashboard — Design
> and Implementation Framework* does not name ODK Central, or any other
> platform. Section 5 states that the identity and capabilities of the
> collection platform "were not included in the material supplied" and lists
> platform questions for the institution's ICT team to answer; Sections 8 and
> 22 are deliberately vendor-neutral. This document therefore assumes ODK
> Central because that is the platform in question, not because the framework
> specifies it. Where it
> depends on a Central behaviour, that is called out so it can be confirmed
> against the deployed version.

---

## 1. The decision that matters: map modules, not questions

The instinctive approach is a mapping table with one row per form question:
`form X, question Q → KPI 6`. It does not survive contact with a real portfolio.

- Sixteen projects authoring their own forms means sixteen unrelated question
  sets per indicator, and a mapping table that grows with the product of forms
  and questions.
- Every form revision invalidates rows in it, and MELIA maintains it by hand.
- It cannot produce the eight KPIs that require `COUNT(DISTINCT …)`. A question
  answered "42 partners trained" is un-deduplicatable: nothing in the number
  says *which* partners, so two projects that trained the same partner both
  report it and the institutional figure is wrong by construction.
- It has nowhere to put a denominator, so percentage KPIs get averaged.

**Map a form module to an indicator instead**, and name the handful of paths
inside that module that carry meaning. A module is a small, reusable block —
a training event with an attendee roster, a publication record, a variety
release — that projects embed rather than reinvent.

This is a two-stage translation, and the middle stage is the point:

```
ODK form (churns constantly)
      │
      ▼
canonical result event  ── "a training event happened; here are the attendees"
      │                     (almost never changes)
      ▼
project indicator ─► program KPI ─► institutional KPI
```

Forms change every season. The shape of a training event does not. Binding
indicators to the stable middle layer means a form revision is a form revision,
not a KPI outage.

---

## 2. How ODK Central concepts land in the schema

| ODK Central | Schema object | Notes |
|---|---|---|
| Central server | `source_system` | `platform = 'odk_central'`, `integration_mode = 'api'` |
| Project | `source_form.external_project_ref` | Central's own project id, not `kpi.project` |
| Form + version | `source_form` | **One row per version.** Mappings bind to a version |
| Form field | `source_form_field` | Discovered from the published definition; lets mappings be validated against real paths |
| Submission | `source_submission` | Keyed on `instanceID` for idempotent re-ingestion |
| Raw submission body | `staging_record.payload` | Retained untransformed (architecture layer 4) |
| Repeat group row | one row counted by a mapping | `source_mapping.repeat_path` |
| Entity List / Dataset | `kpi.entity` | The registry behind every distinct count |
| Review state | `observation.status` | See §7 |
| Attachment | `kpi.evidence` | For indicators with `requires_evidence` |

The binding itself is `kpi.source_mapping`: one row per (form version, project
indicator), carrying a `value_mode` and the paths that mode needs.

---

## 3. Six form-design rules

These are what make the mapping possible. They are form-authoring constraints,
enforced by review of the module library rather than by the database.

**1. Collect rosters, not counts.** Never ask "how many attended?". Ask for one
repeat-group row per attendee. The count is then derived, and it is auditable.

**2. Never ask for a percentage that can be derived.** There is no
"% female" question anywhere. KPI 4a, 5a, 6a and 7a are computed from the sex
attribute on the roster rows of their parent KPI. A separately reported share
*will* eventually disagree with its own numerator; a derived one cannot.

**3. Reference entities; do not re-key names.** For anything counted distinctly
— students, delivery partners, ARIs, scaling partners, innovations, varieties —
the roster row must carry a stable identifier selected from an Entity List, not
a free-typed organisation name. "Green Harvest Cooperative" and "Green Harvest
Co-op Ltd" are one partner; only an identifier knows that.

**4. Code answers; never free-text a dimension.** Sex, age band, degree level,
country all come from `select_one` with fixed codes. Free text means the
`GEO_CODED` data-quality rule fires and the record is held.

**5. Carry the denominator when the indicator is a ratio.** KPI 18–20 need both
"proposals with an inclusion component" and "approved proposals in total". Both
are collected; neither is a percentage.

**6. One module, one result type.** A form that reports training *and*
publications *and* policy engagements cannot be versioned or retired
independently per indicator. Split it.

---

## 4. The five value modes

`source_mapping.value_mode` says how submission rows become a numerator. The
check constraint on the table enforces that each mode carries the paths it
needs.

| Mode | Used for | Required paths |
|---|---|---|
| `distinct_entity` | KPI 4, 5, 6, 7, 8, 11, 12, 13, 14, 17 | `repeat_path`, `entity_ref_path`, `entity_type` |
| `count_rows` | Counts with no de-duplication requirement | `repeat_path` |
| `sum_field` | KPI 1, 3, 15, 16 — additive quantities | `value_path` |
| `value_field` | KPI 10 — a single status reading | `value_path` |
| `ratio_fields` | KPI 2, 9, 18, 19, 20 | `value_path`, `denominator_path` |

---

## 5. Worked example — KPI 6, delivery partners trained

The hardest case: a distinct count, sex-disaggregated, where the same partner is
trained by several projects.

### 5.1 The form module

An Entity List `delivery_partners` holds the registry, with properties
`partner_name`, `partner_type` and `country`. The training module selects from
it rather than accepting typed names.

*survey sheet (abbreviated):*

| type | name | label | save_to |
|---|---|---|---|
| `date` | `event_date` | Date of training | |
| `select_one countries` | `country` | Country | |
| `begin_repeat` | `attendee` | Attendees | |
| `select_one_from_file delivery_partners.csv` | `partner_id` | Partner organisation | |
| `select_one sex` | `sex` | Sex of participant | |
| `select_one yesno` | `completed` | Completed the course | |
| `end_repeat` | | | |

*choices sheet:* `sex` offers `F` / `M` / `other`, labelled in full. The **code**
is what travels; the label is for the enumerator.

Two things to notice. The roster gives the count, the sex split and the
de-duplication key from one structure. And there is no "number trained" field at
all — a typed total would be a second source of truth, free to disagree.

### 5.2 The mapping

```sql
-- The Central server and the form version.
insert into kpi.source_system (code, name, platform, base_url, integration_mode)
values ('ODK_CENTRAL', 'Institutional ODK Central', 'odk_central',
        'https://odk.example.org', 'api');

insert into kpi.source_form (source_system_id, external_project_ref,
                             external_form_id, form_version, title, project_id)
select s.id, '7', 'training_event', '2025.3', 'Training event (standard module)', p.id
from kpi.source_system s, kpi.project p
where s.code = 'ODK_CENTRAL' and p.code = 'PRJ-CAS-01';

-- One row binds the module to the project's KPI 6 indicator.
insert into kpi.source_mapping (
    source_form_id, project_indicator_id, value_mode,
    repeat_path, entity_ref_path, entity_label_path, entity_type,
    observed_on_path, country_path, row_filter,
    mapping_status, effective_from, validated_by, validated_at, note)
select f.id, pi.id, 'distinct_entity',
       'attendee',                 -- the repeat group
       'attendee/partner_id',      -- stable identifier -> kpi.entity
       'attendee/partner_name',    -- only used when registering a new entity
       'organization',
       'event_date',
       'country',
       'attendee/completed = ''yes''',   -- attendance alone is not "trained"
       'validated', date '2025-01-01', 'melia.lead', now(),
       'Standard training module v2025.3.'
from kpi.source_form f
join kpi.project_indicator pi on pi.project_id = f.project_id
join kpi.indicator_definition idef
  on idef.id = pi.indicator_definition_id and idef.code = 'KPI_6'
where f.external_form_id = 'training_event' and f.form_version = '2025.3';

-- Sex answers become the SEX disaggregation. The value_map lets each form keep
-- its own coding without anyone editing the form.
insert into kpi.source_mapping_dimension
    (source_mapping_id, dimension_id, field_path, value_map)
select m.id, d.id, 'attendee/sex',
       '{"F":"F","M":"M","female":"F","male":"M","1":"F","2":"M"}'::jsonb
from kpi.source_mapping m, kpi.dimension d
where d.code = 'SEX'
  and m.source_form_id = (select id from kpi.source_form
                           where external_form_id = 'training_event'
                             and form_version = '2025.3');
```

### 5.3 What the transform then does

For each submission:

1. Record it in `source_submission` keyed on `instanceID`.
2. Read the rows at `repeat_path`, dropping those failing `row_filter`.
3. Resolve each `partner_id` to a `kpi.entity`, following `merged_into_id`.
4. Group the surviving rows by their SEX category.
5. Insert one `observation` per group, with `numerator` = distinct entities in
   that group, plus its `observation_category` and `observation_entity` rows.
6. Link submission to observations via `source_submission_observation`.

Note step 5 writes both the number and the entities behind it. The deferred
contract trigger in `03_results.sql` rejects the transaction if they disagree —
a transform bug cannot quietly publish a wrong count.

Everything above this line is per-project. De-duplication across projects and
programs happens once, in the rollup views, by counting entity rows rather than
adding project figures. In the demo dataset that is the difference between an
institutional KPI 6 of **125** and a naive **272**.

---

## 6. Two shorter examples

### KPI 18 — percentage of approved proposals with inclusion components

A ratio, so both parts are collected and neither is a percentage.

```sql
insert into kpi.source_mapping (source_form_id, project_indicator_id, value_mode,
                                value_path, denominator_path, observed_on_path,
                                mapping_status, validated_by, validated_at)
values (:form_id, :project_indicator_id, 'ratio_fields',
        'proposals_with_inclusion', 'proposals_approved_total', 'reporting_date',
        'validated', 'melia.lead', now());
```

The engine carries numerator and denominator to every level and divides once, so
three projects reporting 3/10, 1/2 and 4/8 give 8/20 = 40% — not the 43.3% that
averaging the percentages would produce.

### KPI 9 — genetic gain, weighted by trial count

```sql
insert into kpi.source_mapping (source_form_id, project_indicator_id, value_mode,
                                value_path, denominator_path, weight_path,
                                observed_on_path, commodity_path,
                                mapping_status, validated_by, validated_at)
values (:form_id, :project_indicator_id, 'ratio_fields',
        'gain_pct', 'gain_basis', 'trial_count', 'assessment_date', 'crop',
        'validated', 'melia.lead', now());
```

`weight_path` is what keeps the weighting alive above project level: the weight
accumulates upward, so a 2.0% gain over 100 trials and a 0.5% gain over 300
trials combine to 0.875%, not the 1.25% a simple average would give.

---

## 7. Extraction

**Endpoint.** Central exposes an OData feed per form:
`/v1/projects/{projectId}/forms/{xmlFormId}.svc/Submissions`. Repeat groups
appear as their own entity sets (`Submissions.attendee`) — convenient, because
roster rows are exactly what the roster-based modes need. Confirm the exact
paths against the deployed Central version.

**Incremental pulls.** Filter on `__system/submissionDate` and store the high
water mark on `ingestion_batch.source_reference`. Nightly is enough: the
framework's own recommendation (section 8.1) is scheduled batch over real-time,
since nothing here reports more often than monthly.

**Idempotency.** `source_submission (source_form_id, instance_id)` is unique.
Re-pulling an overlapping window updates rather than duplicates. This matters:
Central submissions can be *edited* after the fact, which changes the data
without changing the instanceID.

**Raw retention.** The untransformed payload lands in `staging_record.payload`
before any mapping is applied, so a published figure can always be traced back
to what the platform actually sent.

**Review state.** Central's `__system/reviewState` maps onto the schema's
approval workflow:

| Central | `observation.status` |
|---|---|
| `approved` | `validated` |
| `hasIssues` | `submitted` + a `dq_flag` |
| `rejected` | `rejected` |
| `edited` / null | `submitted` |

Only `validated` observations with no open blocking flag reach a published
figure. Everything else stays in the table and in the audit trail.

---

## 8. Validation

Failures are recorded, never dropped. Two places catch them:

**At ingestion**, against `dq_rule`. Out-of-range percentages, negative counts
and unresolvable references never become observations at all — they stay in
`staging_record` with `process_status = 'flagged'` and a `dq_flag`. This is why
the demo dataset shows staged records that were never transformed.

**At write**, by the database. The contract trigger enforces that required
disaggregation is present, that a denominator exists exactly when the indicator
is a ratio, and that a distinct count's numerator matches the entities listed.
These are not advisory: a transform that gets them wrong aborts.

Unresolved entity identifiers become `entity_duplicate_candidate` rows for a
data steward to merge or reject, before any distinct count runs.

---

## 9. Versioning and change control

The rule: **mappings are never edited in place.** To change one, retire the
existing row (`mapping_status = 'retired'`, set `effective_to`) and insert a
replacement. `source_mapping_live_uq` permits only one non-retired mapping per
form version and indicator.

This is what keeps historical figures reproducible. A form revised in June 2026
gets a new `source_form` row; the FY2025 figures continue to resolve through the
mapping that was effective when they were collected.

When a form is republished in Central:

1. The integration job detects the new version and inserts a `source_form` row.
2. Its fields are catalogued into `source_form_field`.
3. Existing mappings are **not** carried over automatically. Each is reviewed
   against the new field list and either re-created or deliberately dropped.
4. Until a mapping is validated for the new version, submissions against it
   stage but do not transform — visible as a completeness gap rather than as
   silence.

Step 3 is manual on purpose. Auto-carrying a mapping onto a revised form is how
a renamed field silently starts feeding the wrong indicator.

---

## 10. Who does what

| Role | Responsibility |
|---|---|
| MELIA | Owns the module library and every `source_mapping`; validates mappings |
| Data/ICT | Runs extraction, maintains `source_form` / `source_form_field` |
| Data steward | Resolves duplicate-entity candidates before distinct counts run |
| Project teams | Collect using library modules; do not author indicator fields |
| Program leaders | Confirm which indicators their projects report |

`kpi.v_indicator_collection_coverage` is the standing report for this: it lists
every project indicator with no validated mapping and no manual-entry route —
i.e. every indicator that will silently report nothing.

---

## 11. Open items to confirm with the institution

Carried forward from framework section 5.1, narrowed to this integration:

1. Central version, and whether the Entities feature is available and in use.
2. Whether an Entity List of partners/students already exists, or must be
   established — this is a prerequisite for eight of the twenty KPIs.
3. Whether projects will accept a shared module library, or whether per-project
   forms must be mapped individually as an interim.
4. Authentication for the integration account, and whether SSO is required.
5. Existing identifier schemes for students and partners (registration numbers,
   ROR) that the entity registry should adopt rather than invent.
6. Retention and PII rules for roster rows, given `entity.is_personal_data`.

Until 1–3 are answered, the mapping layer works but the module library — the
thing that makes it scale past a handful of forms — cannot be built.

---

## 12. Checklist for onboarding one indicator

- [ ] Indicator exists in `indicator_definition` with an agreed aggregation method
- [ ] `distinct_entity_type` set if the method is `distinct_count`
- [ ] Required dimensions declared in `indicator_dimension`
- [ ] A form module exists that collects it per the six rules in §3
- [ ] Entity List in place if the indicator de-duplicates
- [ ] `source_form` row for the exact published version
- [ ] `source_mapping` row with the right `value_mode` and paths
- [ ] `source_mapping_dimension` rows for each required dimension
- [ ] Mapping validated by MELIA (`mapping_status = 'validated'`)
- [ ] `project_indicator_contribution` links it to a program KPI
- [ ] Test submission produces the expected observation, slices and entities
- [ ] Indicator no longer appears in `v_indicator_collection_coverage` as a gap
