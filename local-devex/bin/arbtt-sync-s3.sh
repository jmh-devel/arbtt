#!/usr/bin/env bash
# arbtt-sync-s3.sh  (v2 — raw sample export)
#
# Cron: */15 * * * *
# Exports new raw arbtt samples since last run and uploads to S3 v2 path.
# State tracked in ~/.arbtt/v2-sync-state.json  (no aggregate/delta logic).
#
# S3 path: arbtt/v2/{source_id}/{year}/{month}/{day}/{timestamp}-samples.jsonl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ENV_FILE="${ARBTT_SYNC_ENV_FILE:-$SCRIPT_DIR/arbtt-sync-s3.env}"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
LOCK_FILE="${ARBTT_SYNC_LOCK_FILE:-$HOME/.cache/arbtt-sync-s3.lock}"
LOG_FILE="${ARBTT_SYNC_LOG_FILE:-$REPO_ROOT/local-devex/arbtt-munge/grafana/cron.log}"
CAPTURE_LOG="${ARBTT_CAPTURE_LOG:-$HOME/.arbtt/capture.log}"
STATE_FILE="${ARBTT_V2_STATE_FILE:-$HOME/.arbtt/v2-sync-state.json}"

S3_BUCKET="${ARBTT_S3_BUCKET:?'ARBTT_S3_BUCKET not set'}"
SOURCE_ID="${ARBTT_SOURCE_ID:?'ARBTT_SOURCE_ID not set'}"
AWS_REGION="${ARBTT_AWS_REGION:-us-west-2}"

EXPORTER="$SCRIPT_DIR/arbtt-export-raw.py"
PYTHON_BIN="$(which python3)"

MAX_ATTEMPTS="${ARBTT_PRODUCER_MAX_ATTEMPTS:-5}"
RETRY_BASE="${ARBTT_PRODUCER_RETRY_BASE_SECONDS:-2}"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$LOCK_FILE")" "$(dirname "$LOG_FILE")"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    # Another instance is running
    exit 0
fi

exec >>"$LOG_FILE" 2>&1

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[$TS] arbtt-sync-s3 v2 start"

# Sanity checks
if [[ ! -f "$CAPTURE_LOG" ]]; then
    echo "Missing capture log: $CAPTURE_LOG"
    exit 1
fi
if [[ ! -x "$EXPORTER" ]]; then
    echo "Exporter not executable: $EXPORTER"
    exit 1
fi
if ! command -v aws &>/dev/null; then
    echo "aws CLI not found"
    exit 1
fi

# ---------------------------------------------------------------------------
# Determine start date from state
# ---------------------------------------------------------------------------
TODAY=$(date -u +%Y-%m-%d)
TOMORROW=$(date -u -d "tomorrow" +%Y-%m-%d)

LAST_SAMPLE_TIME=""
if [[ -f "$STATE_FILE" ]]; then
    LAST_SAMPLE_TIME=$(python3 -c "
import json, sys
try:
    d = json.load(open('$STATE_FILE'))
    print(d.get('last_sample_time', ''))
except: print('')
" 2>/dev/null || true)
fi

START_DATE="${LAST_SAMPLE_TIME:0:10}"
if [[ -z "$START_DATE" || "$START_DATE" < "$TODAY" ]]; then
    START_DATE="$TODAY"
fi

TMP_DIR=$(mktemp -d /tmp/arbtt-sync-v2.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT
TMP_FILE="$TMP_DIR/samples.jsonl"
TMP_FILTERED="$TMP_DIR/filtered.jsonl"

# ---------------------------------------------------------------------------
# Export samples
# ---------------------------------------------------------------------------
echo "  Exporting samples: start=$START_DATE (last_sample_time='$LAST_SAMPLE_TIME')"

"$PYTHON_BIN" "$EXPORTER" \
    --logfile "$CAPTURE_LOG" \
    --start "$START_DATE" \
    --end "$TOMORROW" \
    --source-id "$SOURCE_ID" \
    --output "$TMP_FILE" \
    2>&1

if [[ ! -f "$TMP_FILE" ]] || [[ ! -s "$TMP_FILE" ]]; then
    echo "  No new samples — done"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] arbtt-sync-s3 v2 done (no data)"
    exit 0
fi

# Filter out samples already uploaded (sample_time > last_sample_time)
if [[ -n "$LAST_SAMPLE_TIME" ]]; then
    python3 -c "
import json
cutoff = '$LAST_SAMPLE_TIME'
with open('$TMP_FILE') as f, open('$TMP_FILTERED', 'w') as out:
    for line in f:
        rec = json.loads(line)
        if rec['sample_time'] > cutoff:
            out.write(line)
"
else
    cp "$TMP_FILE" "$TMP_FILTERED"
fi

LINE_COUNT=$(wc -l < "$TMP_FILTERED" 2>/dev/null || echo 0)
if [[ "$LINE_COUNT" -eq 0 ]]; then
    echo "  No new samples since last upload — done"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] arbtt-sync-s3 v2 done (no new data)"
    exit 0
fi

echo "  New samples: $LINE_COUNT"

# ---------------------------------------------------------------------------
# Group by date and upload
# ---------------------------------------------------------------------------
RUN_TS=$(date -u +%Y-%m-%dT%H-%M-%SZ)

python3 -c "
import json, glob
from collections import defaultdict
buckets = defaultdict(list)
with open('$TMP_FILTERED') as f:
    for line in f:
        rec = json.loads(line.strip())
        key = (rec['p_year'], rec['p_month'], rec['p_day'])
        buckets[key].append(line.strip())
for (y, m, d), lines in sorted(buckets.items()):
    out_file = f'$TMP_DIR/{y}-{m}-{d}.jsonl'
    with open(out_file, 'w') as fout:
        fout.write('\n'.join(lines) + '\n')
    print(f'{y}|{m}|{d}|{out_file}|{len(lines)}')
" > "$TMP_DIR/parts.txt"

NEW_MAX_SAMPLE_TIME=""

while IFS='|' read -r Y M D PART_FILE PART_COUNT; do
    S3_KEY="arbtt/v2/${SOURCE_ID}/${Y}/${M}/${D}/${RUN_TS}-samples.jsonl"
    S3_URI="s3://${S3_BUCKET}/${S3_KEY}"

    echo "  → $S3_URI  ($PART_COUNT samples)"

    attempt=1
    while true; do
        if aws s3 cp "$PART_FILE" "$S3_URI" \
                --region "$AWS_REGION" \
                --content-type "application/x-ndjson" \
                --no-progress 2>&1; then
            break
        fi
        if (( attempt >= MAX_ATTEMPTS )); then
            echo "Upload failed after $attempt attempts: $S3_URI"
            exit 1
        fi
        sleep_s=$(( RETRY_BASE * (2 ** (attempt - 1)) ))
        echo "  Upload attempt $attempt failed; retrying in ${sleep_s}s"
        sleep "$sleep_s"
        attempt=$(( attempt + 1 ))
    done

    PART_MAX=$(python3 -c "
import json
lines = [l for l in open('$PART_FILE').readlines() if l.strip()]
if lines:
    print(max(json.loads(l)['sample_time'] for l in lines))
" 2>/dev/null || true)
    if [[ -n "$PART_MAX" ]] && [[ -z "$NEW_MAX_SAMPLE_TIME" || "$PART_MAX" > "$NEW_MAX_SAMPLE_TIME" ]]; then
        NEW_MAX_SAMPLE_TIME="$PART_MAX"
    fi

done < "$TMP_DIR/parts.txt"

# ---------------------------------------------------------------------------
# Update state file
# ---------------------------------------------------------------------------
if [[ -n "$NEW_MAX_SAMPLE_TIME" ]]; then
    python3 -c "
import json, os
state = {}
if os.path.exists('$STATE_FILE'):
    try: state = json.load(open('$STATE_FILE'))
    except: pass
state['last_sample_time'] = '$NEW_MAX_SAMPLE_TIME'
state['last_upload_ts'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
state['samples_this_run'] = $LINE_COUNT
json.dump(state, open('$STATE_FILE', 'w'), indent=2)
print(f'  State updated: last_sample_time=$NEW_MAX_SAMPLE_TIME')
"
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] arbtt-sync-s3 v2 done ($LINE_COUNT samples uploaded)"
