#!/usr/bin/env bash
# =============================================================================
#  guard_lib.sh — minimal, dependency-free helpers shared by the SAFETY-CRITICAL
#  hook (hook_log.sh, a fresh standalone process per tool call) and the rest of
#  the API (via common.sh). Deliberately tiny and self-contained:
#    - no `set -e`, no $RC2_ROOT / color / terminal assumptions
#    - no source-time side effects (only function defs)
#  so the hook can source it by absolute path, GUARDED (`... || true`), without
#  risking its contract ("always logs, never breaks the hunt"). Idempotent.
#
#  State-location convention (R11): signals the hook must read WITHOUT jq, fast
#  and robustly, live in plain files (logs/guard.mode, logs/.guard_secret,
#  logs/.flag_mode, logs/.stop, logs/.submitted); structured counters/state the
#  hook reads WITH jq live in logs/accounting.json. Keep new state on that split.
# =============================================================================

# rc2_json_update <file> <jq-filter> [jq-args...] — atomic, FAIL-OPEN read-modify-write of a JSON
# file: jq into a temp, swap in only on success + non-empty output, else leave the original untouched.
# Centralizes the tmp+mv+2>/dev/null pattern (one atomicity/fail-open contract instead of ~15 copies).
#   rc2_json_update "$ACCT" '.global.experiments += 1'
#   rc2_json_update "$ACCT" '.x[$h]=$v' --arg h "$h" --argjson v 1
rc2_json_update() {
  local f="$1"; shift
  local filter="$1"; shift
  [ -s "$f" ] || return 0
  # Concurrency: the per-call hook (one process EACH tool call) + guard/status/health loops all update
  # the same files (accounting.json). A FIXED tmp name let two writers clobber one tmp (corrupt/empty
  # reads), and an unlocked read-modify-write lost increments (counter undercount). Fix = a PRIVATE tmp
  # (pid+random, so mv is always atomic and a reader never sees a half-written file) + an flock that
  # SERIALIZES the read-modify-write (so each updater reads the latest and no increment is lost).
  # Fail-open throughout: a missing flock, a lock timeout, or any jq/mv failure skips the update and
  # returns 0 — it never blocks or crashes the hunt.
  local tmp="${f}.tmp.$$.${RANDOM}"
  _rc2_ju_apply() {   # the atomic bit: jq over the CURRENT file -> private tmp -> atomic mv
    if jq "$@" "$filter" "$f" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then mv "$tmp" "$f" 2>/dev/null
    else rm -f "$tmp" 2>/dev/null; fi
  }
  if command -v flock >/dev/null 2>&1; then
    ( flock -w 5 9 || exit 0; _rc2_ju_apply "$@" ) 9>"${f}.lock" || true
  else
    _rc2_ju_apply "$@"   # no flock: private tmp still prevents torn reads; RMW may still race
  fi
  unset -f _rc2_ju_apply 2>/dev/null || true
  return 0
}

# rc2_mode_rank <off|warn|block> — total order for comparing guard modes (unknown -> off).
rc2_mode_rank() { case "$1" in block) echo 3;; warn) echo 2;; *) echo 1;; esac; }

# rc2_guard_tag <mode> <secret-file> — the tag that authenticates a live guard.mode so the solver
# cannot forge it (the secret is a dotfile it is forbidden to read). Empty if the secret is absent.
rc2_guard_tag() {
  local mode="$1" secf="$2"
  [ -s "$secf" ] || { echo ""; return 0; }
  printf '%s%s' "$mode" "$(cat "$secf" 2>/dev/null)" | md5sum 2>/dev/null | cut -c1-32
}

# rc2_guard_effective <rundir> — the enforced guard mode = the STRONGER of the operator FLOOR
# (RC2_GUARD env; neither solver nor supervisor can go below it) and the supervisor LIVE level
# (logs/guard.mode, honoured only if its tag matches logs/.guard_secret). off < warn < block.
rc2_guard_effective() {
  local rundir="$1" floor="${RC2_GUARD:-off}" live="off"
  local gm="$rundir/logs/guard.mode" sec="$rundir/logs/.guard_secret" m t
  case "$floor" in off|warn|block) ;; *) floor=off;; esac
  if [ -s "$gm" ] && [ -s "$sec" ]; then
    m="$(sed -n 's/^mode=//p' "$gm" 2>/dev/null | head -1 | tr -cd 'a-z')"
    t="$(sed -n 's/^tag=//p'  "$gm" 2>/dev/null | head -1 | tr -cd '0-9a-f')"
    [ -n "$m" ] && [ -n "$t" ] && [ "$t" = "$(rc2_guard_tag "$m" "$sec")" ] && case "$m" in off|warn|block) live="$m";; esac
  fi
  if [ "$(rc2_mode_rank "$live")" -gt "$(rc2_mode_rank "$floor")" ]; then echo "$live"; else echo "$floor"; fi
}

# rc2_is_frozen <rundir> <hypothesis> — true(0) if frozen either by the solver (ledger.json
# .freeze.frozen) OR by the arbiter judge (accounting.json .arbiter_freezes[h], which the solver
# cannot clear). Needs jq; false on any read error.
rc2_is_frozen() {
  local rundir="$1" h="$2" led="$1/ledger.json" acct="$1/logs/accounting.json"
  [ "$(jq -r --arg h "$h" '.hypotheses[$h].freeze.frozen // false' "$led" 2>/dev/null)" = "true" ] && return 0
  [ -n "$(jq -r --arg h "$h" '.arbiter_freezes[$h] // empty' "$acct" 2>/dev/null)" ] && return 0
  return 1
}

# rc2_guard_core_on — true if a guard ENFORCEMENT layer is active: an operator floor (RC2_GUARD!=off)
# or the oversee live-gate (RC2_GATE=1). Callers that also run on the judge-only watcher add
# `|| RC2_GUARD_WATCH=1` plus their own NO_* opt-out; oversee's gate predicate is exactly this core
# (it deliberately omits GUARD_WATCH — watch is judge-only and must not arm the live gate).
rc2_guard_core_on() { [ "${RC2_GUARD:-off}" != "off" ] || [ "${RC2_GATE:-0}" = "1" ]; }

# ── stuck-debate channel (synchronous, turn-based critic↔solver dialogue) ──────────────────────────
# A debate is a blocking, bidirectional conversation opened by oversee ONLY when the solver is stuck:
# oversee critiques, the solver may rebut/ask/revise, up to RC2_DEBATE_MAX_ROUNDS, until oversee RESOLVEs
# or forces a decision. While a debate is OPEN the hook blocks the solver's target-acting tools and only
# lets it read/research and write its reply + planning files — so the dialogue cannot be ignored.
# State convention (R11): the hook must read these WITHOUT jq, fast and robustly, so they are PLAIN files:
#   logs/.debate_turn   — "solver" | "critic"  (presence of a non-empty file == a debate is OPEN)
#   logs/.debate_msg    — the critic's current message to the solver (the hook injects this)
#   logs/.debate_reply  — the solver's current response (oversee reads this; the solver writes it)
#   logs/debate.md       — durable transcript, both sides, append-only (resume memory; oversee owns it)
# Structured round/outcome state lives in accounting.json .debate (oversee manages it with jq).

# rc2_debate_turn <rundir> — echo "solver" | "critic" | "" (no open debate). Dependency-free.
rc2_debate_turn() {
  local f="${1:-.}/logs/.debate_turn" t
  [ -s "$f" ] || { echo ""; return 0; }
  t="$(tr -cd 'a-z' < "$f" 2>/dev/null)"
  case "$t" in solver|critic) echo "$t";; *) echo "";; esac
}

# rc2_debate_active <rundir> — true(0) iff a debate is open.
rc2_debate_active() { [ -n "$(rc2_debate_turn "$1")" ]; }

# rc2_debate_owner <rundir> — echo the critic role that OWNS the open debate ("oversee" | "auditor" | "").
# Set atomically at open-time (see scripts/lib/debate.sh); the hook reads it only to name the critic.
rc2_debate_owner() { local f="${1:-.}/logs/.debate_owner"; [ -s "$f" ] && tr -cd 'a-z' < "$f" 2>/dev/null; }

# rc2_debate_allowed <turn> <tool> <file_path> — true(0) if this tool call is permitted DURING a debate.
# solver turn: read/research freely + write ONLY the reply/planning files (so it can rebut + revise, never
#   act on the target). critic turn: read-only (it waits; it may re-read context, nothing else).
# Everything else (Bash, Task, target MCP, writing exploit code) is blocked. Dependency-free; default-deny.
rc2_debate_allowed() {
  local turn="$1" tool="$2" fp="$3"
  case "$tool" in
    Read|Glob|Grep|NotebookRead|LS|TodoWrite) return 0 ;;
  esac
  [ "$turn" = "solver" ] || return 1   # critic turn (solver waiting): only the read-family above
  case "$tool" in
    WebSearch|WebFetch) return 0 ;;     # research during the solver's turn is encouraged (addresses drought)
    Write|Edit|MultiEdit)
      case "$fp" in
        */.debate_reply|.debate_reply|*/debate.md|debate.md \
        |*/hypotheses.md|hypotheses.md|*/worldmodel.md|worldmodel.md \
        |*/journal.md|journal.md|*/ledger.json|ledger.json) return 0 ;;
        *) return 1 ;;
      esac ;;
  esac
  return 1
}
