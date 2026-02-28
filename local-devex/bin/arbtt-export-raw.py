#!/usr/bin/env python3
"""
arbtt-export-raw.py  —  parse arbtt-dump output into raw per-sample JSONL.

One output record per 60-second arbtt sample. Applies the devex categorize
rules in Python so no Haskell re-execution is needed.

Usage:
  arbtt-export-raw.py [--logfile FILE] [--start YYYY-MM-DD] [--end YYYY-MM-DD]
                      [--output FILE|-] [--source-id ID]

Output: JSONL, one record per sample, schema matches arbtt_samples v2.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, date, timezone, timedelta

# ---------------------------------------------------------------------------
# Categorize rules (mirrors categorize-devex.cfg)
# ---------------------------------------------------------------------------

IDLE_THRESHOLD_MS = 15_000  # $idle > 15 ==> tag inactive


def _is_inactive(idle_ms: int) -> bool:
    return idle_ms > IDLE_THRESHOLD_MS


def _project(program: str, title: str) -> str | None:
    """Return project name or None."""
    # VS Code workspace pattern: "FILE - REPO - Visual Studio Code"
    m = re.search(r' - ([^-]+) - Visual Studio Code$', title)
    if m:
        return m.group(1).strip()
    # Path-based patterns
    m = re.search(r'/(?:data/src/dev-env|home/[^/]+/(?:src|code|projects))/([^/ )]+)', title)
    if m:
        return m.group(1).strip()
    # Explicit title keywords
    if 'dagobah-infra' in title:
        return 'dagobah-infra'
    if 'tacitsoft-diagnostics' in title:
        return 'tacitsoft-diagnostics'
    if 'auto-marketing' in title:
        return 'auto-marketing'
    if re.search(r'solarops[\._\-]us', title, re.I):
        return 'solarops_us'
    return None


def _tool_family(program: str) -> str | None:
    BROWSERS = {'brave-browser', 'firefox', 'google-chrome', 'chromium'}
    EDITORS = {'code'}
    TERMINALS = {'terminator', 'gnome-terminal-server'}
    COMMS = {'signal', 'mattermost'}
    if program in BROWSERS:
        return 'Browser'
    if program in EDITORS:
        return 'Editor'
    if program in TERMINALS:
        return 'Terminal'
    if program in COMMS:
        return 'Comms'
    return None


def _context(program: str, title: str) -> str | None:
    if program == 'code':
        return 'Development'
    if 'Grafana' in title:
        return 'Observability'
    if re.search(r'Gmail|Webmail|Outlook', title):
        return 'Mail'
    if re.search(r'GitHub|GitLab|Bitbucket', title):
        return 'SCM'
    if re.search(r'Jira|Linear|Asana|Notion|Confluence', title, re.I):
        return 'Planning'
    if re.search(r'Calendar', title, re.I):
        return 'Scheduling'
    if re.search(r'YouTube|Netflix|Prime Video|Hulu', title, re.I):
        return 'PersonalMedia'
    if re.search(r'Facebook|Instagram|Reddit|X \(|Twitter', title, re.I):
        return 'Social'
    if program in ('signal', 'mattermost'):
        return 'Comms'
    return None


def _billing_intent(program: str, title: str) -> str | None:
    if program in ('code', 'terminator', 'gnome-terminal-server'):
        return 'billable'
    if re.search(r'GitHub|GitLab|Bitbucket|Jira|Linear|Asana|Confluence', title, re.I):
        return 'billable'
    if re.search(r'Gmail|Webmail|Outlook|Calendar', title, re.I):
        return 'overhead'
    if re.search(r'YouTube|Netflix|Prime Video|Hulu|Facebook|Instagram|Reddit', title, re.I):
        return 'nonbillable'
    return None


def _billing_client(title: str) -> str | None:
    if re.search(r'solarops|SolarOps', title):
        return 'solarops'
    if re.search(r'tacitsoft|dagobah-infra|tacitsoft-diagnostics|Tacitsoft', title, re.I):
        return 'tacitsoft'
    return None


# ---------------------------------------------------------------------------
# Arbtt-dump parser
# ---------------------------------------------------------------------------

HEADER_RE = re.compile(
    r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \((\d+)ms inactive\):$'
)
CURRENT_DESKTOP_RE = re.compile(r'^\s+Current Desktop: (.+)$')
WINDOW_RE = re.compile(
    r'^\s+(\(..\)) \[([^\]]+)\]\s+([^:]+):\s+(.*)$'
)


def parse_dump(lines):
    """Yield one dict per sample from arbtt-dump output lines."""
    sample_time = None
    idle_ms = None
    desktop = None
    focused_program = None
    focused_title = None
    focused_desktop = None

    def emit():
        if sample_time is None:
            return None
        return {
            'sample_time': sample_time,
            'idle_ms': idle_ms,
            'desktop': desktop or focused_desktop,
            'program': focused_program,
            'title': focused_title,
        }

    for raw_line in lines:
        line = raw_line.rstrip('\n')
        m = HEADER_RE.match(line)
        if m:
            if sample_time is not None:
                rec = emit()
                if rec:
                    yield rec
            sample_time = m.group(1)
            idle_ms = int(m.group(2))
            desktop = None
            focused_program = None
            focused_title = None
            focused_desktop = None
            continue

        m = CURRENT_DESKTOP_RE.match(line)
        if m:
            desktop = m.group(1).strip()
            continue

        m = WINDOW_RE.match(line)
        if m:
            status = m.group(1)
            win_desktop = m.group(2).strip()
            prog = m.group(3).strip()
            title = m.group(4).strip()
            if status == '(*)':
                focused_program = prog
                focused_title = title
                focused_desktop = win_desktop
            continue

    # last sample
    if sample_time is not None:
        rec = emit()
        if rec:
            yield rec


# ---------------------------------------------------------------------------
# Record builder
# ---------------------------------------------------------------------------

def build_record(raw: dict, source_id: str) -> dict:
    sample_time_str = raw['sample_time']      # "2026-02-27 07:42:41" (local)
    idle_ms = raw['idle_ms']
    program = raw.get('program') or ''
    title = raw.get('title') or ''
    desktop = raw.get('desktop') or ''

    active = not _is_inactive(idle_ms)

    # Parse local timestamp as-is (arbtt times are local machine time)
    dt = datetime.strptime(sample_time_str, '%Y-%m-%d %H:%M:%S')
    sample_date = dt.strftime('%Y-%m-%d')
    p_year = dt.strftime('%Y')
    p_month = dt.strftime('%m')
    p_day = dt.strftime('%d')

    # Apply categorize rules (only meaningful for active samples)
    project = _project(program, title) if active else None
    tool_family = _tool_family(program) if active else None
    context = _context(program, title) if active else None
    billing_intent = _billing_intent(program, title) if active else None
    billing_client = _billing_client(title) if active else None

    return {
        'sample_time': sample_time_str,
        'sample_date': sample_date,
        'idle_ms': idle_ms,
        'active': active,
        'program': program or None,
        'title': title or None,
        'desktop': desktop or None,
        'project': project,
        'tool_family': tool_family,
        'context': context,
        'billing_intent': billing_intent,
        'billing_client': billing_client,
        'duration_seconds': 60,
        'source_id': source_id,
        # Partition helpers
        'p_year': p_year,
        'p_month': p_month,
        'p_day': p_day,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def run_dump(logfile: str, start: str | None, end: str | None):
    """Stream arbtt-dump output lines."""
    cmd = ['arbtt-dump', '--logfile', logfile]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    for line in proc.stdout:
        yield line
    proc.wait()


def main():
    ap = argparse.ArgumentParser(description='Export raw arbtt samples to JSONL')
    ap.add_argument('--logfile', default=os.path.expanduser('~/.arbtt/capture.log'))
    ap.add_argument('--start', help='Start date YYYY-MM-DD (inclusive)')
    ap.add_argument('--end', help='End date YYYY-MM-DD (exclusive)')
    ap.add_argument('--output', default='-', help='Output file path or - for stdout')
    ap.add_argument('--source-id', default=os.environ.get('ARBTT_SOURCE_ID', 'workstation'))
    args = ap.parse_args()

    start_dt = date.fromisoformat(args.start) if args.start else None
    end_dt = date.fromisoformat(args.end) if args.end else None

    out = open(args.output, 'w') if args.output != '-' else sys.stdout

    count = 0
    for raw in parse_dump(run_dump(args.logfile, args.start, args.end)):
        # Date filtering
        sample_date = raw['sample_time'][:10]
        if start_dt and sample_date < args.start:
            continue
        if end_dt and sample_date >= args.end:
            continue

        rec = build_record(raw, args.source_id)
        out.write(json.dumps(rec, separators=(',', ':')) + '\n')
        count += 1

    if args.output != '-':
        out.close()
        print(f'Exported {count} samples to {args.output}', file=sys.stderr)
    else:
        print(f'Exported {count} samples', file=sys.stderr)


if __name__ == '__main__':
    main()
