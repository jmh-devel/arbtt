#!/usr/bin/env bash
# arbtt-backfill-raw-s3.sh
# Full historical backfill using v2 raw sample schema.
# Uploads one JSONL file per day: arbtt/v2/{source_id}/{year}/{month}/{day}/samples.jsonl
#
# Usage:
#   arbtt-backfill-raw-s3.sh [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--dry-run]
#   (defaults: start = first day with data, end = today)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load env config
ENV_FILE="$SCRIPT_DIR/arbtt-sync-s3.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

# Required config
ARBTT_S3_BUCKET="${ARBTT_S3_BUCKET:?'ARBTT_S3_BUCKET not set'}"
ARBTT_SOURCE_ID="${ARBTT_SOURCE_ID:?'ARBTT_SOURCE_ID not set'}"
ARBTT_AWS_REGION="${ARBTT_AWS_REGION:-us-west-2}"
ARBTT_LOGFILE="${ARBTT_LOGFILE:-$HOME/.arbtt/capture.log}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*" >&2; }

PYTHON_BIN="$(which python3)"
EXPORTER="$SCRIPT_DIR/arbtt-export-raw.py"

DRY_RUN=0
START_DATE=""
END_DATE="$(date +%Y-%m-%d)"   # today (exclusive upper bound)

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --start)   START_DATE="$2"; shift 2 ;;
        --end)     END_DATE="$2";   shift 2 ;;
        --dry-run) DRY_RUN=1;       shift ;;
        *) log_error "Unknown arg: $1"; exit 1 ;;
    esac
done

# Auto-detect start date from first sample in capture.log
if [[ -z "$START_DATE" ]]; then
    log_step "Detecting first sample date from capture.log …"
    FIRST_LINE=$(arbtt-dump --logfile "$ARBTT_LOGFILE" 2>/dev/null | head -1)
    if [[ "$FIRST_LINE" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
        START_DATE="${BASH_REMATCH[1]}"
        log_info "First sample date: $START_DATE"
    else
        log_error "Could not detect first sample date. Use --start YYYY-MM-DD."
        exit 1
    fi
fi

TMP_DIR=$(mktemp -d /tmp/arbtt-backfill-raw.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

log_info "Backfill v2 raw samples"
log_info "  Source:   $ARBTT_SOURCE_ID"
log_info "  Range:    $START_DATE → $END_DATE (exclusive)"
log_info "  Bucket:   s3://$ARBTT_S3_BUCKET"
log_info "  Dry-run:  $DRY_RUN"

# Iterate over each day
current="$START_DATE"
total_days=0
total_samples=0

while [[ "$current" < "$END_DATE" ]]; do
    YEAR="${current:0:4}"
    MONTH="${current:5:2}"
    DAY="${current:8:2}"

    next=$(date -d "$current + 1 day" +%Y-%m-%d)

    S3_KEY="arbtt/v2/${ARBTT_SOURCE_ID}/${YEAR}/${MONTH}/${DAY}/samples.jsonl"
    S3_URI="s3://${ARBTT_S3_BUCKET}/${S3_KEY}"
    TMP_FILE="$TMP_DIR/samples.jsonl"

    log_step "Processing $current …"

    # Export raw samples for this day
    "$PYTHON_BIN" "$EXPORTER" \
        --logfile "$ARBTT_LOGFILE" \
        --start "$current" \
        --end "$next" \
        --source-id "$ARBTT_SOURCE_ID" \
        --output "$TMP_FILE" \
        2>&1 | grep -v '^$' || true

    line_count=0
    if [[ -f "$TMP_FILE" ]]; then
        line_count=$(wc -l < "$TMP_FILE" 2>/dev/null || echo 0)
    fi

    if [[ "$line_count" -eq 0 ]]; then
        log_warn "  No samples for $current — skipping"
        rm -f "$TMP_FILE"
        current="$next"
        continue
    fi

    log_info "  Samples: $line_count → $S3_URI"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        aws s3 cp "$TMP_FILE" "$S3_URI" \
            --region "$ARBTT_AWS_REGION" \
            --content-type "application/x-ndjson" \
            --no-progress
        log_info "  Uploaded ✓"
    else
        log_info "  DRY RUN: would upload $TMP_FILE → $S3_URI"
    fi

    rm -f "$TMP_FILE"
    total_days=$((total_days + 1))
    total_samples=$((total_samples + line_count))

    current="$next"
done

log_info ""
log_info "Backfill complete: $total_days days, $total_samples samples"
