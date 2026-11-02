#!/usr/bin/env bash
# =============================================================================
#  resume_tail.sh — Compact digest of the last N tool calls for resume context.
#
#  Usage:  scripts/resume_tail.sh [N]          (default: 25, from cwd = run dir)
#          scripts/resume_tail.sh 30 /path/to/rundir
#
#  Output: one line per call — timestamp, tool, truncated input (≤150 chars).
#  The solver reads this ON RESUME as a critical thinker: what was I doing,
#  what worked, what didn't, should I continue or change course.
# =============================================================================
set -euo pipefail

N="${1:-25}"
RUN="${2:-.}"
LOG="$RUN/logs/tools.jsonl"

[ -f "$LOG" ] || { echo "(no tools.jsonl found)"; exit 0; }

tail -"$N" "$LOG" | python3 -I -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        ts   = d.get('ts', '?')
        tool = d.get('tool', '?')
        inp  = str(d.get('input', '') or '')
        # For Bash, extract the command; for Read/Write/Edit, extract the path
        if tool == 'Bash' and isinstance(d.get('input'), dict):
            inp = d['input'].get('command', '')
        elif tool in ('Read', 'Write', 'Edit') and isinstance(d.get('input'), dict):
            inp = d['input'].get('file_path', '')
        # For Agent/subagent, show the description
        elif tool == 'Agent' and isinstance(d.get('input'), dict):
            inp = d['input'].get('description', '') or d['input'].get('prompt', '')
        # Truncate
        inp = inp.replace('\n', ' ↵ ')[:150]
        print(f'{ts}  {tool:6s}  {inp}')
    except:
        pass
"
