#!/usr/bin/env python3
"""Generate docs/Schema-Reference.md from the live database catalogue.

Structure (types, keys, constraints, indexes) comes from the database via
tools/schema_introspect.sql. Prose comes from COMMENT ON statements in
schema/10_comments.sql, so it lives with the schema and is visible in psql and
Adminer too. Only the module grouping and its narrative live here.

    make schema-docs

or, by hand:

    psql ... -tAqX -f tools/schema_introspect.sql > schema.json
    python3 tools/build_schema_docs.py schema.json
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "Schema-Reference.md"

# --------------------------------------------------------------------------
# Module grouping. Tables are documented in this order; anything not listed is
# collected into a final "Ungrouped" section so a new table can never be
# silently omitted from the reference.
# --------------------------------------------------------------------------

MODULES = [
    ("Reference data", "01_core.sql",
     "Shared lookups describing *where* and *what* a result concerned. These are "
     "drill-down and filter axes rather than part of any indicator's "
     "disaggregation contract, so they hang off observations as optional "
     "foreign keys.",
     ["country", "location", "commodity", "partner"]),

    ("Organisation hierarchy", "01_core.sql",
     "Institution > Program > Project > Work package. There is one "
     "institution, so `institution` holds one row; it exists because "
     "institutional KPIs and targets need something to hang from.",
     ["institution", "program", "project", "work_package",
      "project_country", "project_commodity", "project_partner"]),

    ("Reporting calendar", "01_core.sql",
     "One calendar for every level. Periods nest through `parent_period_id`, "
     "which is what lets projects report quarterly while the institution "
     "reports annually off the same observations — the two can never disagree "
     "because they are computed from the same rows.",
     ["reporting_period"]),

    ("Disaggregation axes", "01_core.sql",
     "Sex, age band, degree level and anything else results are split by. "
     "Adding an axis is data entry, not a migration.",
     ["dimension", "dimension_category"]),

    ("KPI catalogue", "02_indicators.sql",
     "The KPI inventory of framework section 4.1. One definition per metric, "
     "reused at all three levels, so unit and aggregation method are declared "
     "once and cannot drift between levels.",
     ["kpi_category", "indicator_definition", "indicator_dimension"]),

    ("The three KPI levels", "02_indicators.sql",
     "Each table instantiates a catalogue definition at one level and adds "
     "ownership, baselines and scorecard weighting.",
     ["project_indicator", "program_kpi", "institution_kpi"]),

    ("KPI Mapping Table", "02_indicators.sql",
     "Framework section 10.1. Many-to-many links between levels, versioned "
     "rather than overwritten so that historical figures stay reproducible "
     "when the results framework is realigned mid-year.",
     ["project_indicator_contribution", "program_kpi_contribution"]),

    ("Targets and performance bands", "02_indicators.sql",
     "Separate target tables per level rather than one polymorphic table, so "
     "the foreign keys are real. Bands turn achievement into a traffic light.",
     ["project_indicator_target", "program_kpi_target",
      "institution_kpi_target", "performance_band"]),

    ("Activities and results", "03_results.sql",
     "Steps 1 and 2 of the result chain. `activity_result` is the narrative and "
     "evidence envelope; the numbers live in `observation`, so one reported "
     "result can feed several indicators and slices.",
     ["activity", "activity_partner", "activity_result", "evidence"]),

    ("Countable-entity registry", "03_results.sql",
     "The thing that makes `COUNT(DISTINCT ...)` possible. Eight of the twenty "
     "KPIs count people and organisations that more than one project reports; "
     "a reported total cannot be de-duplicated, but a named list can.",
     ["entity", "entity_duplicate_candidate"]),

    ("Observations", "03_results.sql",
     "The single grain. Every number enters the system here, and every rollup "
     "reads from here.",
     ["observation", "observation_category", "observation_entity"]),

    ("Snapshots", "05_rollups.sql",
     "The rollup views always reflect current data. A snapshot preserves what "
     "was actually reported for a period, so a published figure survives a "
     "later restatement.",
     ["kpi_snapshot"]),

    ("Ingestion and staging", "04_governance.sql",
     "Architecture layers 3 and 4. Raw payloads are retained before "
     "transformation; records that fail validation stop here and never become "
     "observations.",
     ["ingestion_batch", "staging_record"]),

    ("Data quality", "04_governance.sql",
     "Framework section 13. Rules are configuration rather than code. Failures "
     "are flagged and withheld from published figures, never deleted.",
     ["dq_rule", "dq_flag"]),

    ("Access control and audit", "04_governance.sql",
     "Framework sections 15, 16 and 18. Scopes bound a user to an institution, "
     "program or project; the audit log records both data changes and KPI "
     "recalculations.",
     ["app_user", "app_role", "app_user_role", "app_user_scope", "audit_log"]),

    ("Alerts", "04_governance.sql",
     "Framework section 17: performance, reporting, data-quality, target and "
     "stale-data alerts.",
     ["alert_rule", "alert"]),

    ("Source form mapping", "08_source_mapping.sql",
     "How a collection form becomes observations. Maps form *modules* to "
     "indicators, not individual questions — see "
     "[ODK-Central-Integration.md](ODK-Central-Integration.md).",
     ["source_system", "source_form", "source_form_field", "source_mapping",
      "source_mapping_dimension", "source_submission",
      "source_submission_observation"]),
]

# View groupings, in reading order.
VIEW_GROUPS = [
    ("Calculation engine", [
        "v_publishable_observation", "v_period_rollup",
        "v_project_mapping", "v_program_mapping",
        "v_project_indicator_entity", "v_program_kpi_entity",
        "v_institution_kpi_entity",
        "v_project_indicator_value", "v_project_indicator_kpi",
        "v_program_kpi_value", "v_program_kpi_scorecard",
        "v_institution_kpi_value", "v_institution_kpi_scorecard",
    ]),
    ("Totals, headlines and derived indicators", [
        "v_program_kpi_total", "v_institution_kpi_total",
        "v_program_kpi_headline", "v_institution_kpi_headline",
        "v_institution_female_share", "v_institution_kpi_cumulative",
    ]),
    ("Reporting and drill-down", [
        "v_kpi_fact", "v_kpi_lineage",
        "v_institution_scorecard_display",
        "v_institution_category_performance", "v_program_category_performance",
    ]),
    ("Governance", [
        "v_dq_dimension_summary", "v_dq_flag_detail",
        "v_ingestion_summary", "v_indicator_collection_coverage",
    ]),
]

CONSTRAINT_TYPE = {"p": "Primary key", "f": "Foreign key",
                   "u": "Unique", "c": "Check", "x": "Exclusion"}

ERD = """```mermaid
erDiagram
    institution   ||--o{ program : "owns"
    program       ||--o{ project : "owns"
    project       ||--o{ work_package : "may contain"
    project       ||--o{ activity : "implements"
    activity      ||--o{ activity_result : "reports"
    activity_result ||--o{ observation : "produces"

    indicator_definition ||--o{ project_indicator : "instantiated as"
    indicator_definition ||--o{ program_kpi : "instantiated as"
    indicator_definition ||--o{ institution_kpi : "instantiated as"
    kpi_category  ||--o{ indicator_definition : "groups"

    project       ||--o{ project_indicator : "tracks"
    program       ||--o{ program_kpi : "reports"
    institution   ||--o{ institution_kpi : "reports"

    project_indicator ||--o{ project_indicator_contribution : "feeds"
    program_kpi       ||--o{ project_indicator_contribution : "receives"
    program_kpi       ||--o{ program_kpi_contribution : "feeds"
    institution_kpi   ||--o{ program_kpi_contribution : "receives"

    project_indicator ||--o{ observation : "measured by"
    reporting_period  ||--o{ observation : "dates"
    reporting_period  ||--o{ reporting_period : "contains"

    observation   ||--o{ observation_category : "sliced by"
    dimension_category ||--o{ observation_category : "labels"
    dimension     ||--o{ dimension_category : "offers"
    indicator_definition ||--o{ indicator_dimension : "requires"

    observation   ||--o{ observation_entity : "counts"
    entity        ||--o{ observation_entity : "counted in"
    entity        ||--o{ entity : "merged into"

    observation   ||--o{ dq_flag : "may be flagged"
    dq_rule       ||--o{ dq_flag : "raises"
    observation   ||--o{ evidence : "supported by"

    source_form   ||--o{ source_mapping : "bound by"
    project_indicator ||--o{ source_mapping : "fed by"
```"""


def md_escape(text):
    """Escape the few characters that would break a Markdown table cell."""
    if not text:
        return ""
    return text.replace("|", "\\|").replace("\n", " ").strip()


def render_columns(table):
    fks = table["foreign_keys"]
    lines = ["| Column | Type | Null | Default | Description |",
             "|---|---|---|---|---|"]
    for c in table["columns"]:
        default = c["default"]
        if c["identity"]:
            default = "identity"
        elif default and len(default) > 44:
            default = default[:41] + "..."
        desc = md_escape(c["comment"])
        if c["name"] in fks:
            ref = "&rarr; `%s`" % fks[c["name"]]
            desc = (desc + " " + ref).strip() if desc else ref
        lines.append("| `%s` | `%s` | %s | %s | %s |" % (
            c["name"], c["type"],
            "no" if c["not_null"] else "yes",
            "`%s`" % md_escape(default) if default else "",
            desc or ""))
    return lines


def render_table(table):
    out = ["### `%s`" % table["name"], ""]
    if table["comment"]:
        out += [table["comment"], ""]
    out += render_columns(table)

    # Keys and checks worth reading. Foreign keys are already shown per column.
    interesting = [c for c in table["constraints"]
                   if c["type"] in ("p", "u", "c")]
    if interesting:
        out += ["", "**Constraints**", ""]
        for c in interesting:
            out.append("- `%s` &mdash; *%s* `%s`"
                       % (c["name"], CONSTRAINT_TYPE[c["type"]], c["def"]))

    if table["indexes"]:
        out += ["", "**Indexes**", ""]
        for i in table["indexes"]:
            # The leading "CREATE INDEX name ON kpi.table " is noise here.
            body = i["def"]
            marker = " ON kpi.%s " % table["name"]
            if marker in body:
                head, tail = body.split(marker, 1)
                unique = "unique " if head.lower().startswith("create unique") else ""
                body = unique + tail
            out.append("- `%s` &mdash; `%s`" % (i["name"], body))

    out.append("")
    return out


def main():
    src = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else None
    raw = src.read_text() if src else sys.stdin.read()
    d = json.loads(raw)

    by_name = {t["name"]: t for t in d["tables"]}
    grouped = {n for _, _, _, names in MODULES for n in names}
    leftover = sorted(set(by_name) - grouped)

    views_by_name = {v["name"]: v for v in d["views"]}
    grouped_views = {n for _, names in VIEW_GROUPS for n in names}
    leftover_views = sorted(set(views_by_name) - grouped_views)

    L = []
    A = L.append

    # ---- front matter ----------------------------------------------------
    A("# Database schema reference")
    A("")
    A("Complete reference for the `kpi` schema: **%d tables**, **%d views**, "
      "**%d functions**, **%d triggers** and **%d enumerated types**."
      % (len(d["tables"]), len(d["views"]), len(d["routines"]),
         len(d["triggers"]), len(d["enums"])))
    A("")
    A("This document is **generated from the live database** by "
      "`tools/build_schema_docs.py`, so it cannot drift from the schema it "
      "describes. Column descriptions come from `COMMENT ON` statements in "
      "`schema/10_comments.sql`, which means `psql \\d+` and Adminer show the "
      "same text. Regenerate with `make schema-docs`.")
    A("")
    A("For *why* the schema is shaped this way, read "
      "[Schema-Design.md](Schema-Design.md). This file is the *what*.")
    A("")
    A("---")
    A("")

    # ---- contents --------------------------------------------------------
    A("## Contents")
    A("")
    A("- [Conventions](#conventions)")
    A("- [Entity relationships](#entity-relationships)")
    A("- [Enumerated types](#enumerated-types)")
    A("- [Tables](#tables)")
    for title, _, _, _ in MODULES:
        anchor = title.lower().replace(" ", "-").replace(",", "")
        A("  - [%s](#%s)" % (title, anchor))
    if leftover:
        A("  - [Ungrouped](#ungrouped)")
    A("- [Views](#views)")
    A("- [Functions](#functions)")
    A("- [Triggers](#triggers)")
    A("")
    A("---")
    A("")

    # ---- conventions -----------------------------------------------------
    A("## Conventions")
    A("")
    A("These hold throughout, and are not repeated on every table.")
    A("")
    A("**Keys.** Every entity table has a surrogate `id bigint generated always "
      "as identity`. Natural keys (`code`, ISO codes, external references) carry "
      "their own unique constraints. Join tables use composite primary keys "
      "instead of a surrogate.")
    A("")
    A("**Timestamps.** `created_at` and `updated_at` are `timestamptz` "
      "defaulting to `now()`. `updated_at` is maintained by the "
      "`kpi.set_updated_at()` trigger on tables where history matters; the "
      "database is set to UTC so period boundaries are stable regardless of "
      "where a client connects from.")
    A("")
    A("**Soft state, not deletion.** Nothing that has been reported is deleted. "
      "Mappings are `retired`, snapshots are `superseded`, duplicate entities "
      "are `merged_into_id`, and failing records are flagged. This is what makes "
      "a historical figure reproducible.")
    A("")
    A("**Naming.** `_ck` is a check constraint, `_uq` a unique constraint or "
      "index, `_idx` a plain index, `_fkey` a foreign key. Views are prefixed "
      "`v_`. Trigger functions are prefixed `tg_`.")
    A("")
    A("**Approval workflow.** Tables carrying reported data (`activity_result`, "
      "`observation`) share a `status` plus `recorded_by` / `recorded_at` and "
      "`validated_by` / `validated_at`. A check constraint requires the "
      "validation stamp once `status` reaches `validated` or `rejected`. Only "
      "`validated` rows are eligible for publication.")
    A("")
    A("**Effective dating.** Mapping tables carry `mapping_status` plus "
      "`effective_from` / `effective_to`, and a partial unique index permits "
      "only one non-retired row per pair. A `null` `effective_to` means "
      "open-ended. Changing a mapping means retiring the old row and inserting "
      "a new one, never editing in place.")
    A("")
    A("**Deferred contract triggers.** A few checks span more than one table "
      "&mdash; an observation and the rows that justify it. Those run as "
      "`deferrable initially deferred` constraint triggers, firing at commit, so "
      "parent and child rows can be inserted in any order within a transaction. "
      "They raise rather than warn: a transform that violates them aborts.")
    A("")
    A("---")
    A("")

    # ---- ERD -------------------------------------------------------------
    A("## Entity relationships")
    A("")
    A("The core of the model. Governance, staging, access control and alerting "
      "are omitted for legibility; they are documented in full below.")
    A("")
    A(ERD)
    A("")
    A("---")
    A("")

    # ---- enums -----------------------------------------------------------
    A("## Enumerated types")
    A("")
    A("Postgres enums rather than lookup tables, because these are closed sets "
      "that change only with a schema change &mdash; and because an invalid "
      "value then fails at write time rather than surviving to a report.")
    A("")
    A("| Type | Values |")
    A("|---|---|")
    for name in sorted(d["enums"]):
        vals = ", ".join("`%s`" % v for v in d["enums"][name])
        A("| `%s` | %s |" % (name, vals))
    A("")
    A("---")
    A("")

    # ---- tables ----------------------------------------------------------
    A("## Tables")
    A("")
    for title, source_file, blurb, names in MODULES:
        A("## %s" % title)
        A("")
        A("*Defined in `schema/%s`.*" % source_file)
        A("")
        A(blurb)
        A("")
        for n in names:
            if n not in by_name:
                continue
            L.extend(render_table(by_name[n]))
        A("---")
        A("")

    if leftover:
        A("## Ungrouped")
        A("")
        A("Tables not assigned to a module in the generator. If anything appears "
          "here, add it to `MODULES` in `tools/build_schema_docs.py`.")
        A("")
        for n in leftover:
            L.extend(render_table(by_name[n]))
        A("---")
        A("")

    # ---- views -----------------------------------------------------------
    A("## Views")
    A("")
    A("The calculation engine is expressed as views over the observation grain, "
      "so a figure is derived on read and cannot go stale. Snapshots exist for "
      "when a figure must be *frozen* rather than current.")
    A("")
    for gtitle, names in VIEW_GROUPS:
        A("### %s" % gtitle)
        A("")
        for n in names:
            v = views_by_name.get(n)
            if not v:
                continue
            A("#### `%s`" % n)
            A("")
            if v["comment"]:
                A(v["comment"])
                A("")
            A("*Columns:* " + ", ".join("`%s`" % c for c in (v["columns"] or [])))
            A("")
    if leftover_views:
        A("### Ungrouped views")
        A("")
        for n in leftover_views:
            v = views_by_name[n]
            A("#### `%s`" % n)
            A("")
            if v["comment"]:
                A(v["comment"])
                A("")
            A("*Columns:* " + ", ".join("`%s`" % c for c in (v["columns"] or [])))
            A("")
    A("---")
    A("")

    # ---- functions -------------------------------------------------------
    A("## Functions")
    A("")
    plain = [r for r in d["routines"] if not r["trigger"]]
    trig = [r for r in d["routines"] if r["trigger"]]

    A("### Callable functions")
    A("")
    A("| Function | Returns | Description |")
    A("|---|---|---|")
    for r in plain:
        sig = "%s(%s)" % (r["name"], r["args"])
        A("| `%s` | `%s` | %s |" % (sig, r["returns"], md_escape(r["comment"])))
    A("")
    A("### Trigger functions")
    A("")
    A("| Function | Description |")
    A("|---|---|")
    for r in trig:
        A("| `%s()` | %s |" % (r["name"], md_escape(r["comment"])))
    A("")
    A("---")
    A("")

    # ---- triggers --------------------------------------------------------
    A("## Triggers")
    A("")
    A("| Table | Trigger | Timing |")
    A("|---|---|---|")
    for t in d["triggers"]:
        # Keep the part after the trigger name: timing, events and function.
        definition = t["def"]
        marker = "CREATE %sTRIGGER %s " % (
            "CONSTRAINT " if "CONSTRAINT TRIGGER" in definition else "", t["name"])
        timing = definition.split(marker, 1)[-1] if marker in definition else definition
        timing = timing.replace("FOR EACH ROW ", "").replace("ON kpi.%s " % t["table"], "")
        A("| `%s` | `%s` | `%s` |" % (t["table"], t["name"], md_escape(timing)))
    A("")

    OUT.write_text("\n".join(L) + "\n")
    print("wrote %s (%.0f KB, %d lines)"
          % (OUT.relative_to(ROOT), OUT.stat().st_size / 1024, len(L)))
    if leftover:
        print("  note: ungrouped tables ->", ", ".join(leftover))
    if leftover_views:
        print("  note: ungrouped views ->", ", ".join(leftover_views))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
