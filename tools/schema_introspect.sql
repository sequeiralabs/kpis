-- =============================================================================
-- schema_introspect.sql — dump the kpi schema's structure as one JSON document
--
-- Read by tools/build_schema_docs.py to generate docs/Schema-Reference.md.
-- Everything comes from the live catalogue, so the generated reference cannot
-- drift from the schema it describes.
--
--   psql ... -tAqX -f tools/schema_introspect.sql > schema.json
-- =============================================================================

with

enums as (
    select t.typname as name,
           jsonb_agg(e.enumlabel order by e.enumsortorder) as labels
    from pg_type t
    join pg_enum e on e.enumtypid = t.oid
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'kpi'
    group by t.typname
),

tables as (
    select c.oid, c.relname as name, obj_description(c.oid) as comment
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'kpi' and c.relkind = 'r'
),

columns as (
    select a.attrelid as oid,
           jsonb_agg(jsonb_build_object(
               'name',     a.attname,
               'type',     format_type(a.atttypid, a.atttypmod),
               'not_null', a.attnotnull,
               'identity', a.attidentity <> '',
               'default',  pg_get_expr(d.adbin, d.adrelid),
               'comment',  col_description(a.attrelid, a.attnum)
           ) order by a.attnum) as cols
    from pg_attribute a
    join tables t on t.oid = a.attrelid
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
    where a.attnum > 0 and not a.attisdropped
    group by a.attrelid
),

constraints as (
    select con.conrelid as oid,
           jsonb_agg(jsonb_build_object(
               'name', con.conname,
               'type', con.contype,
               'def',  pg_get_constraintdef(con.oid)
           ) order by con.contype, con.conname) as cons
    from pg_constraint con
    join tables t on t.oid = con.conrelid
    group by con.conrelid
),

-- Indexes that are not already implied by a constraint.
indexes as (
    select c.oid,
           jsonb_agg(jsonb_build_object('name', i.indexname, 'def', i.indexdef)
                     order by i.indexname) as idx
    from pg_indexes i
    join tables c on c.name = i.tablename
    where i.schemaname = 'kpi'
      and not exists (select 1 from pg_constraint con
                       where con.conrelid = c.oid and con.conname = i.indexname)
    group by c.oid
),

-- Foreign keys flattened, so each column can name what it points at.
fkeys as (
    select con.conrelid as oid,
           jsonb_object_agg(att.attname,
               ref.relname || '.' || refatt.attname) as fk
    from pg_constraint con
    join tables t on t.oid = con.conrelid
    join lateral unnest(con.conkey, con.confkey) as u(src, tgt) on true
    join pg_attribute att on att.attrelid = con.conrelid and att.attnum = u.src
    join pg_class ref on ref.oid = con.confrelid
    join pg_attribute refatt on refatt.attrelid = con.confrelid and refatt.attnum = u.tgt
    where con.contype = 'f'
    group by con.conrelid
),

table_docs as (
    select jsonb_agg(jsonb_build_object(
               'name',        t.name,
               'comment',     t.comment,
               'columns',     coalesce(c.cols, '[]'::jsonb),
               'constraints', coalesce(k.cons, '[]'::jsonb),
               'indexes',     coalesce(i.idx, '[]'::jsonb),
               'foreign_keys', coalesce(f.fk, '{}'::jsonb)
           ) order by t.name) as v
    from tables t
    left join columns c     on c.oid = t.oid
    left join constraints k on k.oid = t.oid
    left join indexes i     on i.oid = t.oid
    left join fkeys f       on f.oid = t.oid
),

views as (
    select c.oid, c.relname as name, obj_description(c.oid) as comment
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'kpi' and c.relkind = 'v'
),

view_docs as (
    select jsonb_agg(jsonb_build_object(
               'name',    v.name,
               'comment', v.comment,
               'columns', (select jsonb_agg(a.attname order by a.attnum)
                             from pg_attribute a
                            where a.attrelid = v.oid and a.attnum > 0
                              and not a.attisdropped)
           ) order by v.name) as v
    from views v
),

routines as (
    select jsonb_agg(jsonb_build_object(
               'name',    p.proname,
               'args',    pg_get_function_arguments(p.oid),
               'returns', pg_get_function_result(p.oid),
               'trigger', pg_get_function_result(p.oid) = 'trigger',
               'comment', obj_description(p.oid)
           ) order by p.proname) as v
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'kpi'
),

triggers as (
    select jsonb_agg(jsonb_build_object(
               'table', c.relname,
               'name',  tg.tgname,
               'def',   pg_get_triggerdef(tg.oid)
           ) order by c.relname, tg.tgname) as v
    from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'kpi' and not tg.tgisinternal
)

select jsonb_pretty(jsonb_build_object(
    'enums',    (select coalesce(jsonb_object_agg(name, labels), '{}'::jsonb) from enums),
    'tables',   (select coalesce(v, '[]'::jsonb) from table_docs),
    'views',    (select coalesce(v, '[]'::jsonb) from view_docs),
    'routines', (select coalesce(v, '[]'::jsonb) from routines),
    'triggers', (select coalesce(v, '[]'::jsonb) from triggers)
));
