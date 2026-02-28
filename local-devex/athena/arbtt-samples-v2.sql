-- arbtt_samples v2  —  Raw per-sample schema
-- One row per 60-second arbtt capture window.
-- Replaces arbtt_metrics (v1 aggregated delta schema).
--
-- Run via AWS Athena console or CLI:
--   aws athena start-query-execution \
--     --query-string file://arbtt-samples-v2.sql \
--     --result-configuration OutputLocation=s3://tacitsoft-arbtt-prod-494111853453-us-west-2/athena-results/ \
--     --work-group primary
--
-- After creating the table, run the backfill:
--   bin/arbtt-backfill-raw-s3.sh
-- (No MSCK REPAIR needed — partition projection handles discovery automatically.)

CREATE EXTERNAL TABLE IF NOT EXISTS tacitsoft_arbtt.arbtt_samples (
  -- Temporal
  sample_time       string     COMMENT 'Local machine timestamp: YYYY-MM-DD HH:MM:SS',
  sample_date       string     COMMENT 'Date portion: YYYY-MM-DD',
  -- Activity
  idle_ms           int        COMMENT 'System idle time in milliseconds at sample time',
  active            boolean    COMMENT 'true if idle_ms < 15000 (15-second threshold)',
  -- Window context
  program           string     COMMENT 'Focused window program name (X11 WM_CLASS)',
  title             string     COMMENT 'Focused window title text',
  desktop           string     COMMENT 'Active virtual desktop name',
  -- Derived tags (from categorize-devex.cfg rules)
  project           string     COMMENT 'Project name from window title, or null',
  tool_family       string     COMMENT 'Editor|Browser|Terminal|Comms or null',
  context           string     COMMENT 'Development|Observability|Mail|SCM|Planning|Scheduling|Comms|Social|PersonalMedia or null',
  billing_intent    string     COMMENT 'billable|overhead|nonbillable or null',
  billing_client    string     COMMENT 'tacitsoft|solarops or null',
  -- Metrics
  duration_seconds  int        COMMENT 'Always 60 (one arbtt sample interval)',
  source_id         string     COMMENT 'Machine identifier, e.g. workstation-joel'
)
PARTITIONED BY (
  p_source_id string,
  p_year      string,
  p_month     string,
  p_day       string
)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
WITH SERDEPROPERTIES (
  'ignore.malformed.json' = 'true',
  'dots.in.keys'          = 'false'
)
STORED AS TEXTFILE
LOCATION 's3://tacitsoft-arbtt-prod-494111853453-us-west-2/arbtt/v2'
TBLPROPERTIES (
  -- Partition projection: auto-discovers partitions without MSCK REPAIR
  'projection.enabled'                    = 'true',

  'projection.p_source_id.type'           = 'injected',

  'projection.p_year.type'               = 'integer',
  'projection.p_year.range'              = '2025,2035',
  'projection.p_year.digits'             = '4',

  'projection.p_month.type'              = 'integer',
  'projection.p_month.range'             = '1,12',
  'projection.p_month.digits'            = '2',

  'projection.p_day.type'                = 'integer',
  'projection.p_day.range'               = '1,31',
  'projection.p_day.digits'              = '2',

  'storage.location.template'            =
    's3://tacitsoft-arbtt-prod-494111853453-us-west-2/arbtt/v2/${p_source_id}/${p_year}/${p_month}/${p_day}/'
);
