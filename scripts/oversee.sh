#!/usr/bin/env bash
# =============================================================================
#  scripts/oversee.sh <name|slug> ["operator directive"] — supervisor/critic loop.
#
#  Periodically reads a running hunt's logs + living files, has a reviewer model
#  (opus) judge progress vs. rabbit-hole, and writes:
#    runs/<slug>/supervisor.md         — latest verdict; the SOLVER reads & follows it
#    runs/<slug>/logs/supervisor.jsonl — full history (one JSON line per tick)
#  Run it in a 2nd terminal alongside ./hunt (like watch.sh). It never touches the
#  target — it only reads logs and writes advice.
#
#    scripts/oversee.sh blizzard                       # loop, default 600s
#    scripts/oversee.sh blizzard "focus the SSTI on /render, not the login"
#    OVERSEE_INTERVAL=300 scripts/oversee.sh blizzard
#    ONESHOT=1 scripts/oversee.sh blizzard             # one assessment then exit
#    OVERSEE_MODEL=claude-opus-4-8 scripts/oversee.sh blizzard   # pin reviewer model (default: 4.8)
# =============================================================================
set -uo pipefail
. "$(dirname "$0")/lib/reviewer_loop.sh"   # shared scaffolding: env/cache policy, arg-parse, claude call, main loop
rc2_reviewer_parse_args "$@"
# positional back-compat (hunt calls `oversee.sh '<slug>'`): pos[0]=slug, pos[1]=directive, only if the flag was not given
[ -z "$_slug" ] && [ "${#pos[@]}" -ge 1 ] && _slug="${pos[0]}"
[ -z "$_directive" ] && [ "${#pos[@]}" -ge 2 ] && _directive="${pos[1]}"
[ "${#pos[@]}" -gt 2 ] && echo "${y:-}warning: extra positional args ignored — pass model/directive as -m/-d (e.g. -m opus -d \"…\")${n:-}" >&2
# precedence: flag > env > default. Empty slug → newest run (so `-d "…"` alone works).
NAME="$_slug"
OP_NOTE="${_directive:-${OP_NOTE:-}}"
MODEL="${_model:-${OVERSEE_MODEL:-claude-opus-4-8}}"
INTERVAL="${_interval:-${OVERSEE_INTERVAL:-600}}"
[ -n "$_oneshot" ] && ONESHOT=1
RUNDIR="$(rc2_resolve_rundir "$NAME")"
[ -n "${RUNDIR:-}" ] && [ -d "$RUNDIR" ] || { echo "${r}no run dir${NAME:+ for '$NAME'}${n} (pass -s <name>, or start a hunt first)"; exit 1; }
NAME="$(basename "$RUNDIR")"   # normalize to the resolved slug (used by the digest + pgrep)
SUP="$RUNDIR/supervisor.md"
HIST="$RUNDIR/logs/supervisor.jsonl"
SYS="$ROOT/OVERSEER.md"
mkdir -p "$RUNDIR/logs"

# P2 weighted gate (opt-in): escalate the LIVE guard mode only after GATE_N consecutive rabbit-hole
# verdicts about the SAME focus. On by RC2_GATE=1 or whenever an operator floor is set (RC2_GUARD!=off).
# R5 (intentional, not a bug): this predicate decides whether OVERSEE may move the LIVE tier. It is
# NOT the same as hunt's watcher predicate — hunt also honours RC2_GUARD_WATCH (judge-only, no gate).
# Here: the gate is on if the operator set any floor (RC2_GUARD!=off) or explicitly opted in (RC2_GATE=1).
GATE=0; rc2_guard_core_on && GATE=1   # core = floor(RC2_GUARD!=off) or RC2_GATE=1 (guard_lib; see note there)
GATE_N="${RC2_GATE_N:-2}"
GATE_MODE="${RC2_GATE_MODE:-block}"

# ── stuck-debate (synchronous critic↔solver dialogue; opened only when the solver is stuck) ──────────
# On by RC2_DEBATE=1 or whenever a guard layer is on (same convention as the surrender gate); NO_DEBATE=1
# forces off. oversee is the SOLE driver of the turn protocol: it opens a debate on a stuck signal, writes
# the critic's side, reads the solver's logs/.debate_reply each turn, and closes with RESOLVED or a forced
# decision after DMAX rounds. The hook does the blocking; oversee does the thinking.
DMAX="${RC2_DEBATE_MAX_ROUNDS:-6}"
DPOLL="${RC2_DEBATE_POLL:-30}"
DMODEL="${RC2_DEBATE_MODEL:-$MODEL}"
DEBATE_ON=0; { [ "${NO_DEBATE:-0}" != "1" ] && { [ "${RC2_DEBATE:-0}" = "1" ] || rc2_guard_core_on; }; } && DEBATE_ON=1

build_digest(){
  local tj="$RUNDIR/logs/tools.jsonl" elapsed="?" now; now=$(date +%s)
  [ -f "$RUNDIR/logs/meta.env" ] && { . "$RUNDIR/logs/meta.env" 2>/dev/null; [ -n "${start_epoch:-}" ] && elapsed="$(( (now-start_epoch)/60 ))m"; }
  rc2_load_target "$RUNDIR" 2>/dev/null || true

  [ -n "${OP_NOTE:-}" ] && { echo "## OPERATOR DIRECTIVE (human — HIGHEST priority). Relay to the solver and keep nudging (not on-track) until it actually follows this:"; echo "  $OP_NOTE"; echo; }
  echo "# HUNT DIGEST"
  echo "machine=${machine_name:-$NAME} ip=${target_ip:-?} os=${os_hint:-?} difficulty=${difficulty:-?} elapsed=${elapsed}"
  echo "hunt_running=$(pgrep -f "hunt .*$NAME|claude -p .*$NAME" >/dev/null 2>&1 && echo yes || echo no)"
  echo
  echo "## flags.txt"; sed 's/^/  /' "$RUNDIR/flags.txt" 2>/dev/null
  echo
  echo "## heuristics"
  if [ -f "$tj" ]; then
    echo "  tool_calls(lines)=$(wc -l < "$tj" | tr -d ' ')"
    echo "  confirmed hypotheses=$(grep -ciE 'status:[[:space:]]*confirmed' "$RUNDIR/hypotheses.md" 2>/dev/null)  frozen/refuted=$(grep -ciE 'status:[[:space:]]*(frozen|refuted)' "$RUNDIR/hypotheses.md" 2>/dev/null)"
    echo "  top repeated bash command-stems (first 4 tokens):"
    jq -r 'select(.event=="pre" and .command!=null) | .command' "$tj" 2>/dev/null \
      | awk '{print $1, $2, $3, $4}' | sort | uniq -c | sort -rn | head -8 | sed 's/^/    /'
    echo "  most-hit URLs/endpoints:"
    jq -r 'select(.event=="pre" and .command!=null) | .command' "$tj" 2>/dev/null \
      | grep -oE 'https?://[^ "'"'"']+' | sed -E 's#\?.*##' | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'
    echo "  journal.md last changed: $(stat -c '%y' "$RUNDIR/journal.md" 2>/dev/null | cut -d. -f1) (now $(date '+%F %T'))"
  else echo "  (no tools.jsonl yet)"; fi
  echo
  echo "## worldmodel.md"; sed 's/^/  /' "$RUNDIR/worldmodel.md" 2>/dev/null | head -120
  echo
  echo "## hypotheses.md"; sed 's/^/  /' "$RUNDIR/hypotheses.md" 2>/dev/null | head -140
  echo
  echo "## journal.md (tail)"; tail -40 "$RUNDIR/journal.md" 2>/dev/null | sed 's/^/  /'
  echo
  echo "## trajectory — your prior verdicts (newest first; is the solver HEEDING your last DO NEXT + improving?)"
  if [ -s "$HIST" ]; then
    tail -3 "$HIST" | tac | jq -r '"  [#\(.review) \(.ts) \(.status)] " + ((.verdict|gsub("[\n]";" "))[0:280])' 2>/dev/null
  else echo "  (none yet — first review)"; fi
  echo
  echo "## recent images (Read the most relevant 2-4 to SEE what the solver sees — absolute paths)"
  find "$RUNDIR/loot" "$RUNDIR/enum" "$RUNDIR/exploit" "$RUNDIR/recon" "$RUNDIR/reversing" -maxdepth 5 -type f \
       \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' \) -printf '%T@\t%s\t%p\n' 2>/dev/null \
    | sort -rn | head -10 | awk -F'\t' '{printf "  %s (%d B)\n", $3, $2}'
  echo "## last 60 tool calls (ts tool | command[:240])"
  if [ -f "$tj" ]; then
    jq -r 'select(.event=="pre") | [.ts, .tool, ((.command // (.input|tostring))[0:240])] | @tsv' "$tj" 2>/dev/null \
      | tail -60 | sed 's/^/  /'
  fi
}

# oversee's reviewer lead-in; the call/err/cyber logic is shared (scripts/lib/reviewer_loop.sh).
OVERSEE_LEADIN="This is a hunt digest to review. Per the OVERSEER instructions: first judge whether the trajectory is progressing from the logs + living files, then Read 2-4 relevant screenshots from '## recent images' (images render natively), Read raw logs if needed, synthesize, and output ONLY the verdict in the specified format. Read-only tools only (Read/Glob/Grep)."
_oversee_review(){ rc2_reviewer_call "$1" "$SYS" "$OVERSEE_LEADIN"; }   # $1=model, digest on stdin
_oversee_failed(){ rc2_reviewer_failed "$@"; }
_oversee_cyber(){ rc2_reviewer_cyber "$@"; }

# _oversee_gate <status> <verdict> — the P2 weighted gate. Tracks consecutive rabbit-hole verdicts
# about the SAME FOCUS in accounting.json and, at GATE_N, raises the LIVE guard mode via guard.sh
# (re-asserted each tick); any on-track/minor-drift breaks the streak and releases the gate. Opt-in,
# never fires on error/unknown, and (by guard.sh) can never pull enforcement below the operator floor.
_oversee_gate(){
  local status="$1" verdict="$2" acct="$RUNDIR/logs/accounting.json"
  [ "${GATE:-0}" = "1" ] && [ -s "$acct" ] || return 0
  case "$status" in rabbit-hole|on-track|minor-drift) ;; *) return 0 ;; esac
  local focus fp prev_fp streak gated
  focus="$(printf '%s' "$verdict" | grep -oiE '^FOCUS:.*' | head -1 | sed -E 's/^[Ff][Oo][Cc][Uu][Ss]:[[:space:]]*//' | cut -c1-80)"
  fp="$(printf '%s' "$focus" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"; [ -n "$fp" ] || fp="unspecified"
  prev_fp="$(jq -r '.supervisor.last_fp // ""' "$acct" 2>/dev/null)"
  streak="$(jq -r '.supervisor.consecutive_rabbit_hole // 0' "$acct" 2>/dev/null)"
  gated="$(jq -r '.supervisor.gated // false' "$acct" 2>/dev/null)"

  if [ "$status" = "rabbit-hole" ]; then
    if [ "$fp" = "$prev_fp" ]; then streak=$((streak+1)); else streak=1; fi
    rc2_json_update "$acct" '.supervisor.consecutive_rabbit_hole=$s | .supervisor.last_fp=$fp | .supervisor.last_verdict="rabbit-hole"' --arg fp "$fp" --argjson s "$streak"
    if [ "$streak" -ge "${GATE_N:-2}" ]; then
      if "$ROOT/scripts/guard.sh" "$RUNDIR" "${GATE_MODE:-block}" "rabbit-hole consensus x$streak: $focus" >/dev/null 2>&1; then
        rc2_json_update "$acct" '.supervisor.gated=true'
        echo "   ${r}GATE${n} live→${GATE_MODE:-block}  (rabbit-hole x$streak on '$focus')"
      fi
    else
      echo "   ${y}gate: rabbit-hole streak $streak/${GATE_N:-2} on '$focus' (needs $(( ${GATE_N:-2} - streak )) more to escalate)${n}"
    fi
  else
    if [ "$streak" -gt 0 ] || [ "$gated" = "true" ]; then
      rc2_json_update "$acct" '.supervisor.consecutive_rabbit_hole=0 | .supervisor.last_fp="" | .supervisor.gated=false | .supervisor.last_verdict=$st' --arg st "$status"
      if [ "$gated" = "true" ]; then
        "$ROOT/scripts/guard.sh" "$RUNDIR" off "back to $status — release gate" >/dev/null 2>&1 \
          && echo "   ${g}gate released (live→off; effective falls back to operator floor)${n}"
      fi
    fi
  fi
}

# ── stuck detection: "effort spent without the privilege gap closing" ────────────────────────────────
# Reads only the harness counters (accounting.json) + tools.jsonl — never the solver's self-assessment.
# Echoes "<SIGNAL> <one-line evidence seed>" when a debate SHOULD open, else nothing. Debounced by a
# post-close cooldown so debates don't chain. NUMBERS are placeholders (see env.sh) — the mechanism is
# what's wired here; the thresholds await eval calibration. Priority: S3 (most actionable) > S2 > S1.
_oversee_stuck(){
  local acct="$RUNDIR/logs/accounting.json" tj="$RUNDIR/logs/tools.jsonl"
  [ -s "$acct" ] || { echo ""; return 0; }
  local exp lastp lastclose since
  exp="$(jq -r '.global.experiments // 0' "$acct" 2>/dev/null)"; exp="${exp:-0}"
  lastp="$(jq -r '.progress.last_progress_experiment // 0' "$acct" 2>/dev/null)"; lastp="${lastp:-0}"
  lastclose="$(jq -r '.debate.last_close_exp // -100000' "$acct" 2>/dev/null)"; lastclose="${lastclose:--100000}"
  [ $((exp - lastclose)) -ge "${RC2_DEBATE_COOLDOWN:-25}" ] 2>/dev/null || { echo ""; return 0; }
  since=$((exp - lastp))
  # S3 — research drought. Two paths, both "operating on prior without checking it":
  #   (a) FAILURE path: >= M recent FAILED experiments with no web research interleaved (actively failing,
  #       never looking anything up — the original DarkZero-style signal).
  #   (b) FLOOR path: >= FLOOR actions since ANY web research, regardless of pass/fail — catches the subtler
  #       case where the solver PROGRESSES steadily on unverified prior knowledge and never researches (the
  #       real DarkZero solve leaned on external forest-trust research the solver never actually ran; a
  #       failure-only signal can't see it). "Research" = WebSearch/WebFetch or a `researcher` sub-agent Task.
  # ts strings are lexically ordered → compare directly. Both are judge-gated downstream (critic may PASS).
  if [ -f "$tj" ]; then
    local last_research
    last_research="$(jq -r 'select(.event=="pre" and (.tool=="WebSearch" or .tool=="WebFetch" or (.tool=="Task" and ((.input.subagent_type // "")=="researcher")))) | .ts' "$tj" 2>/dev/null | tail -1)"
    # (a) failure path
    local m="${RC2_DEBATE_DROUGHT_M:-15}" fails nfails first_fail
    fails="$(jq -r 'select(.event=="post" and (.exit!=null) and (.exit!=0)) | .ts' "$tj" 2>/dev/null | tail -n "$m")"
    nfails="$(printf '%s\n' "$fails" | grep -c . )"
    if [ "${nfails:-0}" -ge "$m" ] 2>/dev/null; then
      first_fail="$(printf '%s\n' "$fails" | head -1)"
      if [ -z "$last_research" ] || [ "$last_research" \< "$first_fail" ]; then
        echo "S3 research-drought: $nfails recent experiments FAILED with no web research since — operating purely on prior, and it isn't working (doctrine 20)."; return 0
      fi
    fi
    # (b) floor path — actions since the last research action (counted over tools.jsonl pre-events)
    local floor="${RC2_DEBATE_DROUGHT_FLOOR:-50}" since_research
    if [ -z "$last_research" ]; then
      since_research="$(jq -r 'select(.event=="pre") | .ts' "$tj" 2>/dev/null | wc -l | tr -d ' ')"
    else
      since_research="$(jq -r --arg t "$last_research" 'select(.event=="pre" and .ts > $t) | .ts' "$tj" 2>/dev/null | wc -l | tr -d ' ')"
    fi
    if [ "${since_research:-0}" -ge "$floor" ] 2>/dev/null; then
      echo "S3 research-drought(floor): $since_research actions since any web research (none this run / long stale) — the solver may be building its chain on UNVERIFIED PRIOR knowledge; a pivotal inferred claim should be checked against a live source (doctrine 10 → verify pivotal inferred claims / 20)."; return 0
    fi
  fi
  # S2 — surface grinding: one surface has absorbed >= N calls while the gap has not moved (needs SOME
  # stagnation so broad early enumeration never trips it).
  local topn topname
  topn="$(jq -r '.surfaces // {} | to_entries | (max_by(.value) // {value:0}) | .value' "$acct" 2>/dev/null)"; topn="${topn:-0}"
  topname="$(jq -r '.surfaces // {} | to_entries | (max_by(.value) // {key:"?"}) | .key' "$acct" 2>/dev/null)"
  if [ "$topn" -ge "${RC2_DEBATE_SURFACE_N:-60}" ] 2>/dev/null && [ "$since" -ge $(( ${RC2_DEBATE_STALL_T:-40} / 2 )) ] 2>/dev/null; then
    echo "S2 surface-grinding: surface '$topname' absorbed $topn calls while the privilege gap has not moved in $since experiments (doctrine 10 → conclusiveness, not effort)."; return 0
  fi
  # S1 — gap stagnation (master signal): no new verified fact / confirmed-path rung / loot in T experiments.
  if [ "$since" -ge "${RC2_DEBATE_STALL_T:-40}" ] 2>/dev/null; then
    echo "S1 gap-stagnation: $since experiments since any movement in worldmodel / confirmed_path / loot — time is passing but the privilege gap isn't closing (doctrine 10 → orient by the privilege delta)."; return 0
  fi
  echo ""
}

# build_debate_digest — the (lighter) context handed to the critic each debate turn. Includes the stuck
# signal, the running transcript, the solver's latest reply, and the living board.
build_debate_digest(){
  local acct="$RUNDIR/logs/accounting.json"
  rc2_load_target "$RUNDIR" 2>/dev/null || true
  local round sig surf
  round="$(jq -r '.debate.round // 1' "$acct" 2>/dev/null)"; round="${round:-1}"
  sig="$(jq -r '.debate.seed // "(stuck)"' "$acct" 2>/dev/null)"
  surf="$(jq -r '.surfaces // {} | to_entries[]? | "  \(.key): \(.value)"' "$acct" 2>/dev/null | sort -t: -k2 -rn | head -14)"
  echo "# STUCK-DEBATE — the solver is BLOCKED pending this dialogue (round $round/$DMAX)"
  echo "machine=${machine_name:-$NAME} ip=${target_ip:-?} os=${os_hint:-?} difficulty=${difficulty:-?}"
  echo
  echo "## why this debate opened (the stuck signal the harness measured)"; echo "  $sig"
  echo
  echo "## transcript so far (newest at the bottom)"; sed 's/^/  /' "$RUNDIR/logs/debate.md" 2>/dev/null | tail -120
  echo
  echo "## the solver's latest reply (logs/.debate_reply)"
  if [ -s "$RUNDIR/logs/.debate_reply" ]; then sed 's/^/  /' "$RUNDIR/logs/.debate_reply" 2>/dev/null | head -80; else echo "  (none yet — this is the OPENING turn; state the problem + what you demand)"; fi
  echo
  echo "## worldmodel.md (privilege map + verified facts)"; sed 's/^/  /' "$RUNDIR/worldmodel.md" 2>/dev/null | head -90
  echo
  echo "## hypotheses.md (the board)"; sed 's/^/  /' "$RUNDIR/hypotheses.md" 2>/dev/null | head -90
  echo
  echo "## per-surface effort (calls; a lopsided pile = a surface ground or a surface untouched)"; echo "${surf:-  (none)}"
}

# The debate DRIVER (open/turn/close/ownership) is shared in scripts/lib/debate.sh; oversee configures it
# for its role via the RC2_DBG_* globals below and provides the strategy stuck-check. The auditor does the
# same for its own role — whichever sidecar detects a stuck signal FIRST atomically claims the one debate.
export RC2_DBG_ON="$DEBATE_ON" RC2_DBG_ROLE="oversee" RC2_DBG_MODEL="$DMODEL" RC2_DBG_SYS="$SYS" \
       RC2_DBG_HIST="$HIST" RC2_DBG_MAX="$DMAX" RC2_DBG_POLL="$DPOLL" RC2_DBG_DIGEST_FN="build_debate_digest"
RC2_DBG_LEADIN_OPEN="A cheap COUNTER (fixed thresholds) flagged a POSSIBLE stuck signal — it can only count effort, it cannot see context. YOU are the judge: read the actual evidence (the signal seed, the board, the privilege map, the recent journal/logs — Read/Glob/Grep as needed) and decide whether the solver is GENUINELY stuck enough to justify BLOCKING it. If this is legitimately deep work on a complex surface, a long-running scan, or a chain that is still advancing, it is a FALSE POSITIVE — output 'DEBATE: PASS' and a one-line reason, and do NOT open. ONLY if it is really stuck, OPEN the debate (you, the strategy critic, calling the SOLVER): do NOT praise; name the dead/over-ground paths and the untested high-value lever, and demand a specific revised plan or an evidence-backed rebuttal. Output EXACTLY the debate verdict format (DEBATE: PASS|CONTINUE, then TO SOLVER:)."
RC2_DBG_LEADIN_TURN="You are MID-debate with the solver. Read its latest reply above. If it has produced a sound, evidence-grounded revised plan (or convinced you its current path is right), RESOLVE. Otherwise keep pressing — say exactly what is still wrong and what you need. Do not concede to assertion without evidence, and do not nag a solver that has actually answered. Output EXACTLY the debate verdict format (DEBATE: CONTINUE|RESOLVED, then TO SOLVER:)."
export RC2_DBG_LEADIN_OPEN RC2_DBG_LEADIN_TURN

# rc2_sidecar_stuck_check — the open hook the shared mainloop calls each normal tick (see reviewer_loop.sh).
# oversee opens on a STRATEGY stuck signal (S1/S2/S3). The atomic claim in rc2_debate_open_if_stuck makes
# it race-free against the auditor opening on its own signal at the same moment.
rc2_sidecar_stuck_check(){
  local s; s="$(_oversee_stuck)"; [ -n "$s" ] || return 0
  rc2_debate_open_if_stuck "${s%% *}" "${s#* }"
}

assess(){
  local rev="$1" digest verdict ts status cur new rc intervened
  digest="$(build_digest)"
  ts="$(date '+%F %T')"
  echo "${c}[oversee]${n} review #$rev @ $ts (${MODEL}) ..."
  verdict="$(printf '%s\n' "$digest" | _oversee_review "$MODEL")"; rc=$?

  # A content-based [cyber] safeguard re-trips on the same digest, so a fresh session won't clear it —
  # the lever is a less-restricted model. If OVERSEE_FALLBACK_MODEL is set, retry ONCE with it.
  if _oversee_failed "$rc" "$verdict" && _oversee_cyber "$verdict" && [ -n "${OVERSEE_FALLBACK_MODEL:-}" ]; then
    echo "${y}   [cyber] reviewer flagged — retrying once with OVERSEE_FALLBACK_MODEL=$OVERSEE_FALLBACK_MODEL${n}"
    verdict="$(printf '%s\n' "$digest" | _oversee_review "$OVERSEE_FALLBACK_MODEL")"; rc=$?
  fi

  if _oversee_failed "$rc" "$verdict"; then
    status="error"
  else
    status="$(printf '%s' "$verdict" | grep -oiE 'STATUS:[[:space:]]*(on-track|minor-drift|rabbit-hole)' | head -1 \
              | grep -oiE 'on-track|minor-drift|rabbit-hole' | tr 'A-Z' 'a-z')"; status="${status:-unknown}"
  fi
  intervened=false; { [ "$status" = "minor-drift" ] || [ "$status" = "rabbit-hole" ]; } && intervened=true

  jq -cn --arg ts "$ts" --arg rev "$rev" --arg st "$status" --arg v "$verdict" --argjson iv "$intervened" \
     '{ts:$ts, review:($rev|tonumber), status:$st, intervened:$iv, verdict:$v}' >> "$HIST" 2>/dev/null

  _oversee_gate "$status" "$verdict"   # P2: consensus-gated live-mode escalation (opt-in; no-op on error/unknown)

  if [ "$status" = "on-track" ]; then
    echo "${g}   on-track — no intervention (supervisor.md untouched)${n}"
    printf '%s\n' "$verdict" | grep -iE '^[[:space:]]*(STATUS|READ|GOOD):' | sed 's/^/   /'
    return 0
  fi
  # error / unknown → NEVER write a directive or bump the tick (the solver would then follow garbage).
  if [ "$intervened" != "true" ]; then
    if _oversee_cyber "$verdict"; then
      echo "${r}   [cyber] reviewer flagged by safeguards — supervisor.md + tick UNCHANGED.${n}"
      echo "${d}   (a fresh session won't clear a content-based flag; set OVERSEE_FALLBACK_MODEL=<less-restricted model> or apply to the Cyber Verification Program)${n}"
    elif [ "$status" = "error" ]; then
      echo "${y}   reviewer call failed — supervisor.md + tick UNCHANGED (logged as error).${n}"
    else
      echo "${y}   reviewer returned no parseable STATUS — supervisor.md + tick UNCHANGED.${n}"
    fi
    return 0
  fi

  new="$(rc2_write_supervisor "$RUNDIR" "$status" "$(printf '_review #%s · model=%s_\n\n%s' "$rev" "$MODEL" "$verdict")")"
  local tag="${y}minor-drift${n}"; [ "$status" = "rabbit-hole" ] && tag="${r}RABBIT-HOLE${n}"
  echo "   ${tag} → wrote supervisor.md (SUPERVISOR_TICK $new)"
  printf '%s\n' "$verdict" | sed -n '1,14p' | sed 's/^/   /'
}

echo "${c}[oversee]${n} watching $RUNDIR  (model=$MODEL interval=${INTERVAL}s)"
echo "${d}   reviews on each new activity; writes $SUP ONLY on drift/rabbit-hole; every review → $HIST ; Ctrl+C to stop${n}"
[ -n "$OP_NOTE" ] && echo "${y}   operator directive active:${n} $OP_NOTE ${d}(relayed to solver until followed)${n}"
if [ "$GATE" = "1" ]; then echo "${y}   weighted gate ON:${n} ${GATE_N} consecutive same-focus rabbit-holes → live guard '${GATE_MODE}' (re-asserted; never below operator floor)"
else echo "${d}   weighted gate off (advisory only; set RC2_GATE=1 or RC2_GUARD=warn|block to enable auto-escalation)${n}"; fi
if [ "$DEBATE_ON" = "1" ]; then echo "${y}   stuck-debate ON:${n} oversee calls the solver on a strategy signal (S1 gap-stagnation / S2 surface-grind / S3 research-drought) → BLOCKS it and runs a turn-based dialogue (≤${DMAX} rounds, poll ${DPOLL}s). The auditor may open its own on an evidence signal — whoever is first atomically owns it."
else echo "${d}   stuck-debate off (set RC2_DEBATE=1 or RC2_GUARD=warn|block; NO_DEBATE=1 forces off)${n}"; fi
# the shared mainloop is debate-aware: it drives a debate turn each tight poll while one is open (owner-only),
# runs the normal activity-gated review otherwise, and calls rc2_sidecar_stuck_check (above) to open one.
rc2_reviewer_mainloop "$RUNDIR" "$INTERVAL" assess oversee
