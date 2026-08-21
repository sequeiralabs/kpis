# Sample surveys and how they map to indicators

Three XLSForms in [`surveys/`](../surveys), ready to upload to ODK Central, each
demonstrating one of the mapping patterns in
[ODK-Central-Integration.md](ODK-Central-Integration.md). Their mappings are
loaded into the database by `schema/09_survey_mappings.sql`, so every example
here is a real row you can query.

| Form | Pattern | Feeds |
|---|---|---|
| `training_event.xlsx` | `distinct_entity` × 2 | KPI 6, KPI 7 (and 6a, 7a by derivation) |
| `proposal_inclusion.xlsx` | `ratio_fields` × 3 | KPI 18, 19, 20 |
| `variety_trial.xlsx` | `ratio_fields` + weight, `distinct_entity` | KPI 9, KPI 8 |

Regenerate them with `python3 tools/build_surveys.py` (needs `openpyxl`); the
form definitions live in that script, so edits are reviewable as code.

---

## Loading them into ODK Central

1. **Create the media attachments first.** Each form uses
   `select_one_from_file`, so it needs its CSV. Upload the files in
   `surveys/media/` as *Form Attachments* when publishing:

   | Form | Needs |
   |---|---|
   | `training_event` | `delivery_partners.csv`, `national_scientists.csv` |
   | `variety_trial` | `varieties.csv` |
   | `proposal_inclusion` | none |

2. **Upload the `.xlsx`** in Central under *New Form*, then publish it.

3. **Fill one submission per form** in Collect or Enketo, using the rosters
   rather than typing totals.

> **On the CSVs.** In production these are not static files. Central publishes
> an Entity List to forms under the same filename, so the form itself does not
> change when you switch over — only where the file comes from. Shipping static
> CSVs means the forms can be loaded and tested before Entity Lists exist.
> Both have `name` (the stable identifier that lands in `entity.external_ref`)
> and `label` (what the enumerator sees).

---

## 1. `training_event.xlsx` — the distinct-count pattern

The hardest and most important case. Two rosters on one form, feeding two
distinct-count KPIs that are both sex-disaggregated.

### What the form collects

```
event/                          event_title, event_date, country, crop, training_days
has_partners
partner_attendee/     [repeat]  partner_id, partner_sex, partner_completed
has_scientists
scientist_attendee/   [repeat]  scientist_id, scientist_sex, scientist_completed
attendance_sheet                photo, attached as evidence
```

### What it deliberately does not collect

- **No "number trained" question.** The count comes from counting roster rows.
  A typed total would be a second source of truth, free to drift from the roster
  beneath it.
- **No "% female" question.** KPI 6a and 7a are derived from `partner_sex` and
  `scientist_sex` on the same rows that produce the parent. A separately
  reported share will eventually contradict its own numerator; a derived one
  cannot.
- **No typed organisation names.** `partner_id` is a selection from the
  register. This is what makes de-duplication possible at all: "Green Harvest
  Cooperative" and "Green Harvest Co-op Ltd" are one partner, and only an
  identifier knows that.

The form does show the enumerator a derived count in a read-only note, so they
can sanity-check the roster before submitting. It is a display, not a value —
nothing maps to it.

### The mapping

```
KPI 6, delivery partners trained
  value_mode        distinct_entity
  repeat_path       partner_attendee
  entity_ref_path   partner_attendee/partner_id      -> kpi.entity.external_ref
  entity_type       organization
  row_filter        partner_attendee/partner_completed = 'yes'
  observed_on_path  event/event_date
  country_path      event/country
  commodity_path    event/crop
  dimension SEX     partner_attendee/partner_sex

KPI 7, national scientists trained
  ... identical shape against the scientist_attendee roster, entity_type person
```

Two details worth pausing on:

**`row_filter`.** Attending is not the same as being trained. The filter drops
non-completions before anything is counted, at the point where the rule is
visible and reviewable rather than buried in a transform.

**The value map.** `source_mapping_dimension.value_map` translates the form's
answer codes to catalogue categories:

```json
{"F":"F","M":"M","other":"OTHER","female":"F","male":"M","1":"F","2":"M"}
```

A project whose form codes sex as `1`/`2` still lands in the right slice, with
no edit to the form and no separate transform branch.

### What one submission produces

A submission with six completing partner attendees — four female, two male,
one of whom appears twice because two of their staff attended:

| | |
|---|---|
| Observations written | 2 — one per sex slice |
| `SEX=F` slice | numerator 4, four `observation_entity` rows |
| `SEX=M` slice | numerator 1 (the duplicated partner collapses), one entity row |
| Evidence | the attendance photograph, against the observation |

The deferred contract trigger checks that each numerator equals the distinct
entities listed. A transform that miscounts aborts the transaction rather than
publishing.

De-duplication *across* projects happens later, in the rollup views, not here.

---

## 2. `proposal_inclusion.xlsx` — the ratio pattern

Three percentage KPIs off one roster.

### What the form collects

```
period/               reporting_date, country
proposal/  [repeat]   proposal_ref, proposal_title, approval_date,
                      has_gender_youth, has_climate, has_nutrition
                      flag_inclusion / flag_climate / flag_nutrition   [calculate]
proposals_approved_total      = count(${proposal})
proposals_with_inclusion      = sum(${flag_inclusion})
proposals_with_climate        = sum(${flag_climate})
proposals_with_nutrition      = sum(${flag_nutrition})
```

Again, **no percentage is collected**. The form counts proposals and flags; the
engine divides.

### The mapping

All three share a denominator and differ only in numerator:

```
KPI 18   ratio_fields   proposals_with_inclusion  / proposals_approved_total
KPI 19   ratio_fields   proposals_with_climate    / proposals_approved_total
KPI 20   ratio_fields   proposals_with_nutrition  / proposals_approved_total
```

### Why the denominator has to travel

This is the framework's section 6.2 warning made concrete. Three projects report
3/10, 1/2 and 4/8 — that is 30%, 50% and 50%.

- Averaging the percentages gives **43.3%**.
- Recombining the parts gives 8/20 = **40%**.

The second is correct, and it is only available because the denominator survived
the trip up. Collecting a percentage instead of its two parts destroys the
information permanently at the point of data entry — no amount of downstream
cleverness recovers it.

The schema enforces this from both ends: a percentage indicator's observation
*must* carry a denominator, and a contribution mapping *must not* carry an
attribution factor for one, since scaling a numerator alone would change the
ratio.

---

## 3. `variety_trial.xlsx` — weights, and a second pattern on one form

Shows two patterns coexisting, and the one place a weight matters.

### What the form collects

```
assessment/           assessment_date, country, crop
gain/                 gain_pct, gain_basis [=100], trial_count
any_release
release/   [repeat]   variety_id, release_date, gazette_ref, gazette_document
```

### The mapping

```
KPI 9, genetic gain
  value_mode        ratio_fields
  value_path        gain/gain_pct
  denominator_path  gain/gain_basis          (constant 100 - gain is a percentage)
  weight_path       gain/trial_count         <- the important one
  commodity_path    assessment/crop

KPI 8, varieties released
  value_mode        distinct_entity
  repeat_path       release
  entity_ref_path   release/variety_id
  entity_type       variety
  observed_on_path  release/release_date
```

### Why `trial_count` is collected

KPI 9 is an average across crops, and the framework specifies weighting by trial
or plot count. That weight is *data* — it changes every period — not a static
configuration constant.

A 2.0% gain measured over 100 trials and a 0.5% gain over 300 trials combine to:

- **1.25%** if you average the two figures — wrong, and it over-weights the
  small trial by a factor of three.
- **0.875%** weighted by trial count — correct.

`weight_path` is what puts the weight in the observation, and the project view
accumulates it and carries it upward, so the program figure stays weighted
rather than degrading into a simple average of project figures. This is asserted
in the smoke test.

### Why `gazette_ref` is required

KPI 8 has `requires_evidence` set. An observation with no evidence attached
raises the `EVIDENCE_MISSING` rule, which blocks publication until resolved. The
requirement is declared in the catalogue and enforced at ingestion, so the form
asks for it up front rather than the figure being held later.

---

## Checking the mappings in the database

```sql
-- What each form feeds.
select f.external_form_id || ' v' || f.form_version as form,
       idef.code, m.value_mode,
       coalesce(m.repeat_path, m.value_path) as source_path,
       m.row_filter
from kpi.source_mapping m
join kpi.source_form f on f.id = m.source_form_id
join kpi.project_indicator pi on pi.id = m.project_indicator_id
join kpi.indicator_definition idef on idef.id = pi.indicator_definition_id
order by form, idef.code;

-- Which disaggregation each mapping supplies.
select f.external_form_id, d.code as dimension, md.field_path, md.value_map
from kpi.source_mapping_dimension md
join kpi.source_mapping m on m.id = md.source_mapping_id
join kpi.source_form f on f.id = m.source_form_id
join kpi.dimension d on d.id = md.dimension_id;

-- Indicators with no route for data to arrive at all.
select * from kpi.v_indicator_collection_coverage
where coverage = 'NO COLLECTION ROUTE';
```

That last query is the useful one operationally. Three forms cover seven
indicators; the rest of the portfolio has no collection route yet, which is
exactly the gap a module library is meant to close.

---

## What these three do not cover

They are examples of the patterns, not a complete library. Still to be authored,
one module each:

- Publications (KPI 1, 2, 3) — `sum_field`, plus DOI as evidence
- Theses accepted (KPI 5) — `distinct_entity` over `thesis`
- Student enrolment (KPI 4) — `distinct_entity` over `person`, degree-level split
- Innovations catalogued and scaled (KPI 11, 12) — `distinct_entity`
- Collaborations (KPI 13, 14) — `distinct_entity` over `organization`
- Awards and invitations (KPI 15, 16) — `sum_field`
- Policy engagements (KPI 17) — `distinct_entity` over `engagement_event`
- Crop Trust compliance (KPI 10) — `value_field`, latest-status

Each follows one of the five value modes already demonstrated. The work is
agreeing the questions with the responsible team, not inventing a new pattern.
