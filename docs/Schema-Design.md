# KPI database schema — design

A PostgreSQL schema for the three-level KPI structure described in
[Organization-Structure.md](Organization-Structure.md) and a *Program KPI
Dashboard — Design and Implementation Framework* (the source framework document,
which is not distributed with this repository).

Everything lives in the `kpi` schema. Files load in numeric order.

| File | Contents |
|---|---|
| `00_database.sql` | Database-level `search_path` and timezone |
| `01_core.sql` | Enums, org hierarchy, reporting calendar, reference and disaggregation dimensions |
| `02_indicators.sql` | KPI catalogue, the three KPI levels, the KPI Mapping Table, targets |
| `03_results.sql` | Activities, results, entity registry, observations, integrity triggers |
| `04_governance.sql` | Staging, data-quality framework, access control, audit log, alerts |
| `05_rollups.sql` | The calculation engine — views for steps 4–7, snapshots, lineage |
| `06_seed_catalogue.sql` | The 20 KPIs, five categories, calendar, DQ rules, roles |
| `07_demo_data.sql` | Three years of demonstration data with seeded quality problems |
| `08_source_mapping.sql` | Binding collection forms to project indicators |

---

## 1. The shape of the problem

The result chain is a translation across four grains:

```
Activity  ──►  Activity result  ──►  Observation  ──►  Project indicator
                                          │
                                          ├──►  Program KPI
                                          └──►  Institutional KPI
```

Three properties make this harder than a sum:

**Not everything adds.** Percentages must never be summed. Counts of people and
organisations must not be summed either, because the same student or partner is
routinely reported by several projects.

**Figures must be reproducible.** A board pack published in April has to still
reconcile after a project restates a figure in June.

**Every number must be traceable.** An institutional KPI has to resolve to the
field records that produced it, including the ones that were excluded and why.

The schema is organised around those three, not around the org chart.

---

## 2. Core decisions

### 2.1 One indicator definition, reused at every level

`indicator_definition` is the catalogue: unit, value type, aggregation method,
direction, decimal places, whether it is cumulative or indexed. The three level
tables — `project_indicator`, `program_kpi`, `institution_kpi` — instantiate a
definition and add ownership, baselines and targets.

A trigger requires that a project indicator and the program KPI it feeds share
one definition. Unit and aggregation method therefore cannot drift between
levels, which is the failure mode where a program sums what a project averaged.

### 2.2 Observations are the single grain

`observation` is the one place a number enters the system:

```
observation(project_indicator_id, reporting_period_id, activity_result_id?,
            numerator, denominator?, conversion_factor, weight,
            disaggregation_key, country/location/commodity/partner, status)
```

`activity_result_id` is null for direct entry (a survey, an import); non-null
when the value came from a recorded activity. Both paths land in the same table,
so every rollup reads from one place.

### 2.3 Numerator and denominator, all the way up

Percentage and ratio indicators carry both parts at every level. Each level
recombines the parts and divides once. Three projects reporting 3/10, 1/2 and
4/8 give 8/20 = 40% — not the 43.3% that averaging their percentages produces.

A trigger enforces the shape: a denominator exists exactly when the indicator is
a ratio or percentage, and never otherwise.

### 2.4 An entity registry, so distinct counts are possible

Eight of the twenty KPIs aggregate with `COUNT(DISTINCT …)`. A count alone
cannot be de-duplicated: "42 partners trained" does not say *which* 42.

`entity` is a registry of countable things — people, organisations,
publications, theses, varieties, innovations, engagement events, proposals —
with a stable external reference where one exists. `observation_entity` names
the entities behind each count.

`merged_into_id` handles duplicates: when two records turn out to be the same
real-world thing, the loser points at the winner and every count follows the
pointer. Records are merged, never deleted, so the audit trail survives.

The rollups then count entity rows at each level rather than adding up the level
below. In the demo dataset that is the difference between an institutional
KPI 6 of **125** and a naive **272**.

### 2.5 Disaggregation as a contract

`dimension` and `dimension_category` define axes (sex, age band, degree level).
`indicator_dimension` declares which axes apply to an indicator and whether they
are required.

An observation carries one category per applicable axis via
`observation_category`. A trigger keeps a denormalised `disaggregation_key` in
sync, so every rollup can group by one column.

A deferred constraint trigger enforces the contract: required axes present, no
undeclared axes, and — for distinct counts — the numerator matching the entities
actually listed. These abort the transaction. A transform bug cannot quietly
publish a wrong figure.

Because every observation carries a *complete* combination of its required
axes, the slices partition the whole exactly, and totals can combine them
without double counting. Distinct counts are the exception and are recounted
from the entity views rather than summed, since one entity can legitimately
appear in more than one slice.

### 2.6 The "a" sub-indicators are derived, not reported

KPI 4a, 5a, 6a and 7a are female-share percentages of KPIs 4–7. Reporting them
separately guarantees eventual disagreement with their own parent.

`indicator_definition.parent_indicator_id` links them, and
`v_institution_female_share` derives the share from the parent's own sex
disaggregation. The share and the total cannot diverge.

### 2.7 Versioned mappings, never overwritten

`project_indicator_contribution` and `program_kpi_contribution` are the KPI
Mapping Table. They carry `mapping_status`, `effective_from`/`effective_to` and
a validation stamp. Changing a mapping means retiring the old row and inserting
a new one; a partial unique index permits only one live mapping per pair.

This is what keeps historical figures reproducible when the results framework is
realigned mid-year.

`contribution_factor` scales a child's numerator for unit conversion or
attribution. A trigger forbids it on ratio and percentage indicators, where
scaling a numerator without its denominator would change the ratio.

### 2.8 One calendar, many cycles

Reporting periods nest through `parent_period_id` (2025-Q1 → FY2025).
`v_period_rollup` maps each period to itself and to every period containing it,
and the rollups group by the ancestor.

Projects can therefore report quarterly while the institution reports annually,
computed from the same observations. An annual figure and the sum of its
quarters cannot disagree — the smoke test asserts exactly that.

### 2.9 Flagged, not deleted

`v_publishable_observation` is the only input to a published figure: validated
status, and no open blocking data-quality flag. Flagged records stay in the
table and in the audit trail; they are withheld, not removed. Resolving a flag
restores the value with no re-entry.

### 2.10 Computed live, frozen deliberately

The rollup views always reflect current data. `kpi.take_snapshot(period)` writes
a frozen copy across all three levels and supersedes the previous run, so a
published figure survives later restatement. The smoke test checks both halves:
the snapshot matches the live view when taken, and stops matching after a
restatement.

---

## 3. The calculation engine

`05_rollups.sql`, following framework sections 6 and 11.

| View | Step |
|---|---|
| `v_publishable_observation` | 4 — what is allowed to be published |
| `v_project_indicator_value` / `_kpi` | 5 — project-level contribution |
| `v_program_kpi_value` / `_scorecard` | 6 — aggregated across projects |
| `v_institution_kpi_value` / `_scorecard` | 7 — aggregated across programs |
| `v_*_headline` | Whole-KPI figure with target and traffic light |
| `v_*_total` | Combined across disaggregation slices |
| `v_institution_kpi_cumulative` | Running totals for cumulative indicators |
| `v_kpi_fact` | Observation grain with every drill-down dimension |
| `v_kpi_lineage` | An institutional figure back to source records |

Each level view has two branches. The first aggregates the level below by the
indicator's method. The second handles `distinct_count` by counting entity rows
directly — the branch that makes de-duplication work across projects and
programs.

The aggregation methods are the framework's own (section 11):

| Method | Behaviour |
|---|---|
| `sum` | Adds contributions |
| `distinct_count` | Counts distinct entities, following merges |
| `ratio` | Sums numerators and denominators, then divides once |
| `weighted_average` | Σ(w·x)/Σw, with the weight accumulating upward |
| `latest` | Most recent validated observation |
| `average`, `max`, `min` | As named |

Cumulative behaviour is a separate flag rather than a method, because it
describes accumulation across *time*, not how children combine into a parent.

**A note on weights.** `weighted_average` is the subtle one. KPI 9 is weighted
by trial count, which is data that varies per period — not a static mapping
constant. The project view accumulates `total_weight` from the observations and
carries it upward, so the effective weight of a child at its parent is its own
data weight times the mapping weight. Without that, a weighted average silently
degrades into a simple average of project figures one level up.

---

## 4. Governance

`04_governance.sql` covers the framework's architecture layers 3–5 and
sections 13, 15, 16 and 18.

- **Staging** — `ingestion_batch` and `staging_record` retain raw payloads
  before transformation. Records that fail validation stop here and never become
  observations.
- **Data quality** — `dq_rule` is configuration, so MELIA can add checks without
  a deployment. Rules carry a dimension (the framework's seven), a severity and
  whether they block publication. `dq_flag` records failures.
- **Access control** — `app_user`, `app_role`, `app_user_scope`. Scopes bound a
  user to an institution, program or project; `can_view_personal_data` gates
  roster records, which `entity.is_personal_data` marks.
- **Audit** — `audit_log` with a generic row trigger, attached to observations,
  mappings and indicator definitions. Recalculations and snapshots log too.
- **Alerts** — `alert_rule` / `alert` for the five alert types in section 17.

---

## 5. What the schema does not decide

Deliberately left open, because the framework marks them "to be
defined/validated by the institution":

- **KPI definitions and calculation rules.** Every indicator loads with
  `definition_status = 'draft'`. The aggregation methods in `06_seed_catalogue.sql`
  are the framework's *proposals* from section 11.1, not confirmed rules.
- **Targets and baselines.** The source file has none. The demo data derives
  illustrative targets from its own 2023 outturn purely so the traffic lights
  have something to show.
- **The indexed 2025 figures.** `is_indexed` flags them so a dashboard never
  labels them as raw counts, but their basis is unconfirmed.
- **Which platform data arrives from.** `08_source_mapping.sql` is
  platform-neutral; see [ODK-Central-Integration.md](ODK-Central-Integration.md)
  for how it binds to ODK Central specifically.

---

## 6. Verifying it

```
make test      # smoke test: 20 assertions, rolls back
make verify    # asserts the demo dataset loaded as claimed
```

The smoke test is built around the traps in framework section 6.2 — it asserts
the *wrong* answers are not produced:

| Assertion | Wrong answer it rules out |
|---|---|
| Institutional KPI 6 = 3 | 4, from summing two programs of 2 |
| KPI 18 = 40% | 43.3%, from averaging 30/50/50 |
| KPI 9 = 0.875% | 1.25%, from a simple average |
| KPI 10 = 100% | 90% (averaged) or 180% (summed) |
| KPI 6a = 33.3% | 60%, from counting rows rather than entities |
| Flagged value withheld, then restored | Silent deletion |
| Snapshot survives restatement | A "frozen" figure that moves |

Plus four rejection tests: missing required disaggregation, a cross-program
mapping, an attribution factor on a percentage, and a write to a closed period.
