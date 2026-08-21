# Program KPI database

A PostgreSQL schema, calculation engine and dashboard prototype for the
three-level KPI structure in the *Program KPI Dashboard — Design and
Implementation Framework*: **Institution → Program → Project**, with activity
results rolling up through project indicators to program and institutional KPIs.

It covers the framework's twenty KPIs across five categories, and is built
around the three things that make this harder than a sum:

- **Not everything adds.** Percentages are never summed; eight KPIs count people
  and organisations that several projects report, so they are de-duplicated
  rather than added. In the demo data that is the difference between an
  institutional KPI 6 of **125** and a naive **272**.
- **Figures must be reproducible.** Mappings are versioned and never
  overwritten; snapshots freeze what was reported for a period.
- **Every number must be traceable.** An institutional figure resolves to the
  field records that produced it — including the ones excluded, and why.

> The KPI definitions, calculation rules and targets are **draft**. The source
> file supplied only category, ID, name and a 2025 figure; the framework marks
> everything else "to be defined/validated by the institution". The aggregation
> methods loaded here are the framework's own proposals from section 11.1,
> flagged as such, pending a business-rule validation workshop. The framework
> document itself is not distributed with this repository.

---

## Quick start

Requires Docker. Nothing is installed on the host.

```bash
make up          # start Postgres + Adminer + dashboard; loads schema and demo data
make test        # 20 assertions against the calculation engine
make verify      # asserts the demo dataset loaded as claimed
```

First run takes about two minutes — it generates ~3,300 observations across
three financial years and snapshots each of them.

| | |
|---|---|
| Database | `localhost:55432` — database `kpi`, user `kpi`, password `kpi` |
| Adminer | http://localhost:8080 (server `db`) |
| Dashboard | http://localhost:8081 |

```bash
make psql        # interactive session
make scorecard   # FY2025 institutional scorecard
make quality     # data quality across the seven dimensions
make lineage     # one KPI traced back to source records
make reset       # destroy the volume and rebuild from schema/
```

---

## What is here

```
schema/      the database, loaded in numeric order (also the Docker init scripts)
tests/       smoke test and demo-data verification
tools/       dashboard export/build, XLSForm generator
dashboard/   self-contained SPA prototype
surveys/     three sample ODK Central forms and their media CSVs
docs/        design and integration documentation
```

### Schema

| File | Contents |
|---|---|
| `00_database.sql` | Database settings |
| `01_core.sql` | Enums, org hierarchy, reporting calendar, reference and disaggregation dimensions |
| `02_indicators.sql` | KPI catalogue, three KPI levels, KPI Mapping Table, targets |
| `03_results.sql` | Activities, results, entity registry, observations, integrity triggers |
| `04_governance.sql` | Staging, data quality, access control, audit log, alerts |
| `05_rollups.sql` | Calculation engine, snapshots, lineage |
| `06_seed_catalogue.sql` | The 20 KPIs, five categories, calendar, DQ rules, roles |
| `07_demo_data.sql` | 2023–2025 demonstration data with seeded quality problems |
| `08_source_mapping.sql` | Binding collection forms to project indicators |
| `09_survey_mappings.sql` | The three sample forms, mapped |
| `10_comments.sql` | Table, column, view and function descriptions, in the catalogue |

54 tables and 28 views, every one carrying a description in the database
catalogue — so `psql \d+` and Adminer show the same text as the reference
document. The demo data is deterministic — generated from a hash
of each row's own coordinates, so two clean loads are byte-identical.

### Documentation

| Document | What it covers |
|---|---|
| [docs/Schema-Reference.md](docs/Schema-Reference.md) | Complete data dictionary: every table, column, constraint, view, function and trigger |
| [docs/Schema-Design.md](docs/Schema-Design.md) | The design and why each decision was taken |
| [docs/ODK-Central-Integration.md](docs/ODK-Central-Integration.md) | How survey submissions become observations |
| [docs/Sample-Surveys.md](docs/Sample-Surveys.md) | The three sample forms and their mappings |
| [docs/Organization-Structure.md](docs/Organization-Structure.md) | The original hierarchy and result chain |

---

## The result chain

```
Activity implemented by a Project
   ↓
Activity output / result recorded            activity_result
   ↓
Result mapped to a Project Indicator         observation
   ↓
Validated (data-quality checks)              v_publishable_observation
   ↓
Project-level KPI contribution               v_project_indicator_value
   ↓
Aggregated across Projects in a Program      v_program_kpi_value
   ↓
Program KPIs aggregated to Institutional     v_institution_kpi_value
```

Each level view has two branches: one aggregates the level below by the
indicator's method, the other counts entity rows directly for distinct-count
KPIs. That second branch is what stops the same student being counted twice
because two projects reported them.

### Aggregation methods

The framework's six (section 11), plus the ordinary statistical ones:

| Method | Behaviour | KPIs |
|---|---|---|
| `sum` | Adds contributions | 1, 3, 15, 16 |
| `distinct_count` | Counts distinct entities, following merges | 4, 5, 6, 7, 8, 11, 12, 13, 14, 17 |
| `ratio` | Sums numerators and denominators, divides once | 2, 4a–7a, 10, 18, 19, 20 |
| `weighted_average` | Σ(w·x)/Σw, weight accumulating upward | 9 |
| `latest` | Most recent validated observation | 10 |

Cumulative behaviour is a separate flag, not a method: it describes accumulation
across *time*, not how children combine into a parent.

---

## Data quality

Records that fail validation are flagged, never deleted. A blocking flag
withholds the value from published figures until resolved; resolving it restores
the value with no re-entry.

The demo data seeds problems in all seven of the framework's quality dimensions
— completeness, accuracy, consistency, timeliness, validity, uniqueness,
integrity — so the workflow can be exercised on real rows:

```bash
make quality
```

Invalid values never become observations at all. They stay in `staging_record`
with a flag, which is why the ingestion summary shows staged records that were
never transformed.

---

## Dashboard prototype

`dashboard/index.html` is a single self-contained file with no network requests.
It reads the database's own reporting views — nothing is recomputed in the
browser — across five views: overview, scorecard, trends and drill-down, data
quality, and traceability.

```bash
make dashboard   # re-export data from the database and rebuild
```

---

## Regenerating the schema reference

`docs/Schema-Reference.md` is generated from the live catalogue, so it cannot
drift from the schema. After changing anything in `schema/`:

```bash
make reset && make schema-docs
```

---

## Sample surveys

Three XLSForms in `surveys/`, ready to upload to ODK Central, demonstrating the
mapping patterns — a de-duplicated roster, a ratio with its denominator, and a
weighted average. See [docs/Sample-Surveys.md](docs/Sample-Surveys.md).

```bash
python3 tools/build_surveys.py    # regenerate (needs openpyxl)
```

---

## Status and open items

Working and tested: the schema, the calculation engine, the data-quality
framework, the mapping layer, the demo dataset and the dashboard.

Not decided here, because the framework marks them for the institution:

- KPI definitions, numerators/denominators and confirmed calculation rules
- Targets and baselines — the source file has none; the demo derives
  illustrative ones from its own 2023 outturn
- The basis of the indexed 2025 figures (`is_indexed` flags them so a dashboard
  never presents them as raw counts)
- Whether the shared form-module library can be adopted across projects

`kpi.v_indicator_collection_coverage` lists every project indicator with no
route for data to arrive — the standing report for closing that last gap.
