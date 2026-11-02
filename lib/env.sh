#!/usr/bin/env bash
# =============================================================================
#  env.sh — .env loading, SecLists, and flag helpers. Needs $RC2_ROOT (set by
#  bootstrap.sh). Part of the standalone lib; sourced via bootstrap.sh.
# =============================================================================

rc2_load_env() {
  # redcat2's OWN .env — no sibling project is read.
  [ -f "$RC2_ROOT/.env" ] || { echo "no $RC2_ROOT/.env — copy .env.example to .env and fill it"; return 1; }
  set -a; . "$RC2_ROOT/.env"; set +a
  : "${CLAUDE_CODE_OAUTH_TOKEN:?set CLAUDE_CODE_OAUTH_TOKEN (run: claude setup-token) in $RC2_ROOT/.env}"
  # expose ONLY the project venv's CLI tools (pwncat-cs) ahead of a broken system/pipx install — via a
  # dedicated dir, NOT the whole .venv/bin, so we do NOT shadow system `python3`/`pip` with the minimal
  # 3.11 venv (that would break the solver's own scripts: boto3/impacket/pwntools import under the venv).
  # scripts/setup_env.sh populates .venv/exposed with symlinks to just those tools.
  [ -d "$RC2_ROOT/.venv/exposed" ] && export PATH="$RC2_ROOT/.venv/exposed:$PATH"
  # SecLists: prefer an in-folder vendor/ copy (self-contained), then explicit SECLISTS_DIR, then the
  # shared external tree. scripts/vendor.sh populates vendor/ (symlink by default, --copy to internalize).
  if [ -z "${SECLISTS:-}" ]; then
    if [ -e "$RC2_ROOT/vendor/SecLists" ]; then SECLISTS="$RC2_ROOT/vendor/SecLists"
    else SECLISTS="${SECLISTS_DIR:-$HOME/files_etc/SecLists}"; fi
  fi
  export SECLISTS="${SECLISTS/#\~/$HOME}"
  # HTB API client (bundled, sourceable). Non-fatal if absent — IP-only mode still works.
  if [ -f "$RC2_ROOT/scripts/lib/htb_api.sh" ]; then . "$RC2_ROOT/scripts/lib/htb_api.sh"; RC2_HTB=1; else RC2_HTB=0; fi
  unset ANTHROPIC_API_KEY   # force subscription auth; an API key would override + bill per-token

  # ── guard / rabbit-hole calibration defaults — SINGLE SOURCE OF TRUTH ──────────
  # Calibrated from this toolkit's own runs: solved boxes finished in ~186-416 tool calls;
  # a hard rabbit-hole run burned ~832 with no root. .env or the launch env overrides any of
  # these. All EXPORTED so the per-call hook (a separate process) inherits them.
  : "${RC2_CEIL:=800}"             # global experiment hard-stop (~2x slowest solved; the worst rabbit-hole wedged near here)
  : "${RC2_WARN:=450}"             # global experiment warn line (just above the slowest solve, 416)
  : "${RC2_BUDGET_DEFAULT:=8}"     # per-hypothesis attempt budget seeded into ledger.json
  : "${RC2_REPEAT_FREEZE:=4}"      # identical-action repeats on one hypothesis before the hook warns/blocks
  : "${RC2_STALL:=12}"             # experiments on one hypothesis with no new evidence before the judge is asked
  : "${RC2_JOURNAL_STALL:=15}"     # experiments with no journal.md change before the hook nudges to append (memory discipline; always-on)
  : "${RC2_GATE_N:=2}"             # consecutive same-focus rabbit-hole reviews before oversee raises the live mode
  : "${RC2_GATE_MODE:=block}"      # mode oversee escalates the live tier to on consensus
  : "${GUARD_WATCH_INTERVAL:=180}" # sameness-judge watcher cadence, seconds
  : "${GUARD_JUDGE_MODEL:=sonnet}" # sameness judge (haiku=cheaper/coarser; sonnet=safer). Operator has CVP,
                                   # so sonnet is fine here; only opus is capped at 4.8 (see rc2_pin_model).
  : "${RC2_SURRENDER_MAX:=2}"      # max times the surrender gate may re-open a blocker and relaunch
  : "${RC2_SURRENDER_MODEL:=claude-opus-4-8}" # surrender-gate re-audit: an opus reviewer, capped at 4.8 (never 5.x)
  export RC2_CEIL RC2_WARN RC2_BUDGET_DEFAULT RC2_REPEAT_FREEZE RC2_STALL RC2_JOURNAL_STALL RC2_GATE_N RC2_GATE_MODE GUARD_WATCH_INTERVAL GUARD_JUDGE_MODEL RC2_SURRENDER_MAX RC2_SURRENDER_MODEL

  # ── epistemic auditor (conclusiveness gate) — the "premature-surrender one layer deeper" defense ─
  # A periodic, independent opus reader of the RAW logs that judges whether a REFUTED/frozen high-impact
  # hypothesis actually reached the mechanism's verdict, or was abandoned on an INCONCLUSIVE result (a
  # test that never ran: FAULT/timeout/tooling/transport). It writes auditor.md (+ AUDITOR_TICK); the
  # hook PUSHES "read auditor.md" to the solver and escalates to a hard block if ignored. Separate from
  # oversee (strategy/rabbit-hole): this audits EVIDENCE QUALITY. See scripts/auditor.sh, AUDITOR.md.
  : "${AUDITOR_INTERVAL:=420}"        # auditor cadence, seconds (7 min)
  : "${AUDITOR_MODEL:=claude-opus-4-8}" # independent reviewer, capped at 4.8 (semantic "did the mechanism speak?" call)
  : "${AUDITOR_NUDGE_ESCALATE:=3}"    # hook push: warn this many times, then block (exit 2) until the solver reads auditor.md
  : "${RC2_UNTESTABLE_MAX:=4}"        # materially-different INCONCLUSIVE attempts on one vector before it is PARKED (untestable), not refuted
  export AUDITOR_INTERVAL AUDITOR_MODEL AUDITOR_NUDGE_ESCALATE RC2_UNTESTABLE_MAX

  # ── stuck-debate channel (synchronous critic↔solver dialogue, opened only when stuck) ───────────
  # oversee opens a BLOCKING, turn-based debate when it detects the solver is stuck; the hook blocks the
  # solver's target actions and only lets it read/research + write its reply, so the dialogue can't be
  # ignored. The solver may rebut with evidence — it's a dialogue, not a one-way order. Capped at
  # RC2_DEBATE_MAX_ROUNDS, then oversee forces a decision (a SUPERVISOR_TICK). On by RC2_DEBATE=1 or
  # whenever a guard layer is on (same convention as the surrender gate); NO_DEBATE=1 forces it off.
  : "${RC2_DEBATE:=0}"              # 1 = enable the debate gate even with the guard off (else it rides the guard core)
  : "${RC2_DEBATE_MAX_ROUNDS:=6}"  # max critic↔solver exchanges before oversee forces a decision
  : "${RC2_DEBATE_POLL:=30}"       # oversee's poll cadence (s) WHILE a debate is open — tight, so turns feel live
  : "${RC2_DEBATE_MODEL:=claude-opus-4-8}" # the critic in a debate (capped at 4.8, same as oversee)
  # "Stuck" = effort spent without the privilege gap closing. These thresholds are a CHEAP PREFILTER, not
  # the decision: when one trips, oversee asks the critic (opus, context-aware) to JUDGE whether the solver
  # is really stuck or this is legitimately deep work — the critic can decline (DEBATE: PASS). So a single
  # number no longer has to be "right" for every box; it only has to decide "worth asking". Because the
  # judge backstops false positives, these can be set fairly SENSITIVE. The NUMBERS are placeholders
  # (uncalibrated) — tune against eval/; the mechanism (prefilter → judge) is what's wired.
  : "${RC2_DEBATE_STALL_T:=40}"    # S1 gap-stagnation: experiments since last progress before the critic is ASKED
  : "${RC2_DEBATE_SURFACE_N:=60}"  # S2 surface-grinding: calls piled on ONE surface (with no progress) before ASKING
  : "${RC2_DEBATE_DROUGHT_M:=15}"  # S3 research-drought (FAILURE path): failed experiments since the last web search before ASKING
  : "${RC2_DEBATE_DROUGHT_FLOOR:=50}" # S3 research-drought (FLOOR path): actions since ANY web research, regardless of
                                   # failures — catches "progressing steadily on UNVERIFIED PRIOR knowledge, never looking
                                   # anything up" (the DarkZero breakthrough was external research the solver never ran).
                                   # judge-gated like the rest: the critic PASSes if the box genuinely needed no research.
  : "${RC2_DEBATE_COOLDOWN:=25}"   # experiments that must pass after a debate closes before another may open
  : "${RC2_DEBATE_HANG:=1800}"     # dead-critic safety valve: on the critic's turn, release the block if oversee hasn't moved it in this many seconds
  export RC2_DEBATE RC2_DEBATE_MAX_ROUNDS RC2_DEBATE_POLL RC2_DEBATE_MODEL RC2_DEBATE_STALL_T RC2_DEBATE_SURFACE_N RC2_DEBATE_DROUGHT_M RC2_DEBATE_DROUGHT_FLOOR RC2_DEBATE_COOLDOWN RC2_DEBATE_HANG

  # ── surface labeling (A3) ──────────────────────────────────────────────────────
  # Tier-1 (the per-call hook, _hook_surface) is always on, deterministic, multi-label. Tier-2 is the
  # OPT-IN out-of-band model pass that adds INFERRED labels (privesc-candidate, auth-bypass-surface, …)
  # the patterns can't — off by default; enable to enrich the §5 gap/combination digest.
  : "${RC2_SURFACE_TIER2:=0}"             # 1 = enable the Tier-2 inferred-label pass (scripts/surface_label.sh)
  : "${RC2_SURFACE_TIER2_MODEL:=haiku}"   # model for Tier-2 (haiku = cheap distill; sonnet = richer judgment)
  export RC2_SURFACE_TIER2 RC2_SURFACE_TIER2_MODEL

  # ── prompt-cache / relaunch efficiency ────────────────────────────────────────
  # The real lever for "don't re-pay the whole context on every relaunch" is SERVER-SIDE prompt caching —
  # there is NO local prompt cache (verified: code.claude.com/docs/en/prompt-caching). The doctrine system
  # prompt is byte-stable across relaunches, so a longer cache TTL lets a relaunch (or a re-spawned
  # sub-agent) WITHIN the window reuse the cached prefix instead of re-billing ~15K tokens. 1h needs OAuth
  # (subscription) — ANTHROPIC_API_KEY is unset above, which would otherwise force 5m. Reads are 0.1x, so
  # on a hunt that relaunches/forks many times within the hour this is a large net win. Override in .env.
  : "${CLAUDE_CODE_PROMPT_CACHE_TTL:=1h}"            # orchestrator main conversation
  : "${CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL:=1h}"  # researcher/reverser/exploit-dev/... reuse their stable prefix
  : "${DISABLE_AUTOUPDATER:=1}"                      # an auto-update between relaunches would cost a cold turn
  : "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:=0}"    # never kill background tasks (subagents, long shell commands) on a timeout
  export CLAUDE_CODE_PROMPT_CACHE_TTL CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL DISABLE_AUTOUPDATER CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS
}

# rc2_pin_model <requested> — cap OPUS at 4.8, leave every other model alone. Policy (operator has CVP,
# so Claude-5 trips are reduced and sonnet/haiku are fine to use): opus 5.x is the one model that must
# never be called here (it still trips the cyber safeguard hardest and is the costliest), so any opus
# reference above 4.8 — the bare `opus` alias (resolves to newest = 5.x) and any claude-opus-5+ id — is
# pinned down to claude-opus-4-8. Opus 4.x (incl. claude-opus-4-8) is honoured. Sonnet, haiku, and any
# non-opus id pass through UNCHANGED. Escape hatches: RC2_NO_PIN=1 disables; RC2_PIN_MODEL overrides the
# opus cap target (e.g. a vetted CYBER_FALLBACK_MODEL).
rc2_pin_model() {
  local m="${1:-claude-opus-4-8}" pin="${RC2_PIN_MODEL:-claude-opus-4-8}"
  [ "${RC2_NO_PIN:-0}" = "1" ] && { printf '%s' "$m"; return; }
  case "$m" in
    opus)                printf '%s' "$pin" ;;   # bare alias -> newest opus (5.x); cap to 4.8
    claude-opus-4-*)     printf '%s' "$m" ;;      # opus 4.x (incl. 4-8) -> allowed, keep
    claude-opus-[5-9]*)  printf '%s' "$pin" ;;    # opus 5.x and up -> cap to 4.8
    claude-opus-*)       printf '%s' "$pin" ;;    # any other opus id -> cap (safe default)
    *)                   printf '%s' "$m" ;;      # sonnet / haiku / non-opus -> leave UNCHANGED
  esac
}

_rc2_is_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# flag helpers (RC2_FLAG_RE, rc2_flag_value, rc2_hex_in, rc2_both_flags) live in common.sh,
# which bootstrap.sh sources before this file — one source of flag parsing for libs and scripts.
