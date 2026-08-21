-- =============================================================================
-- 00_database.sql — database-level settings, applied before the schema is built
-- =============================================================================

-- So an interactive session lands in the kpi schema without qualifying names.
alter database kpi set search_path to kpi, public;

-- Timestamps are stored as timestamptz; a fixed server timezone keeps reporting
-- period boundaries stable regardless of where a client connects from.
alter database kpi set timezone to 'UTC';
