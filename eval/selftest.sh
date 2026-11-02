#!/usr/bin/env bash
# =============================================================================
#  eval/selftest.sh — the FAST feedback loop the system was missing.
#
#  Rationale (the "A: measurement first" critique): until now the ONLY way a
#  wiring regression was caught was a human watching a live hunt. Two regressions
#  shipped that way — a clobbered PATH and an empty journal seed. These are cheap,
#  deterministic invariants that need no network, no HTB token, and no box. Run
#  this before every change to the launcher/doctrine; a red here is a regression.
#
#  It asserts the launcher's load-bearing invariants by calling the REAL functions
#  (rc2_scaffold / rc2_build_sysprompt / rc2_pin_model), not reimplementing them.
#
#  Usage:  eval/selftest.sh            # run all checks, exit non-zero if any fail
#          eval/selftest.sh -v         # also print detail on PASS
#  Exit:   0 = all pass, 1 = one or more failed.
# =============================================================================
set -u
RC2_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RC2_ROOT"
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
[ -t 1 ] || { G=; R=; Y=; D=; N=; }
PASS=0; FAIL=0; FAILED_NAMES=()

ok()   { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$G" "$N" "$1"; [ "$VERBOSE" = 1 ] && [ -n "${2:-}" ] && printf '       %s%s%s\n' "$D" "$2" "$N"; return 0; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  %sFAIL%s %s\n' "$R" "$N" "$1"; [ -n "${2:-}" ] && printf '       %s%s%s\n' "$Y" "$2" "$N"; return 0; }
# assert_empty NAME DETAIL "<grep-ish output>" : pass when the given capture is empty
assert_empty() { if [ -z "$3" ]; then ok "$1"; else bad "$1" "$2: $(printf '%s' "$3" | head -3 | tr '\n' '|')"; fi; }

echo "redcat self-test  (root: $RC2_ROOT)"
echo

# ── 1. SHELL SYNTAX — catch a broken script before it ever runs ──────────────
echo "[syntax]"
syn_bad=""
while IFS= read -r f; do
  bash -n "$f" 2>/tmp/_syn.$$  || syn_bad+="$f: $(tr '\n' ' ' </tmp/_syn.$$)"$'\n'
done < <(find hunt lib scripts eval tools -type f \( -name '*.sh' -o -name 'hunt' \) 2>/dev/null)
rm -f /tmp/_syn.$$
assert_empty "every shell script parses (bash -n)" "syntax error" "$syn_bad"

# python scripts compile
py_bad=""
while IFS= read -r f; do
  python3 -I -m py_compile "$f" 2>/tmp/_py.$$ || py_bad+="$f: $(tr '\n' ' ' </tmp/_py.$$)"$'\n'
done < <(find scripts eval -type f -name '*.py' 2>/dev/null)
rm -f /tmp/_py.$$
assert_empty "every python script compiles" "compile error" "$py_bad"

# ── 2. PATH INVARIANT — never CLOBBER the operator's PATH (the shipped bug) ──
# A PATH= assignment whose RHS does not reference $PATH drops every existing
# entry — that is exactly the regression that broke tool resolution mid-hunt.
echo
echo "[path]"
path_clobber="$(grep -rnE '(^|[^A-Za-z_])PATH=' hunt lib scripts 2>/dev/null \
  | grep -v '\$PATH' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"
assert_empty "no PATH assignment clobbers \$PATH (prepend/append only)" "clobbering PATH=" "$path_clobber"

# the in-folder CLI dir (.venv/exposed, prepended to PATH) must not symlink OUT of the repo —
# a cp from redcatN left pwncat-cs pointing back into redcatN's venv. Self-containment invariant.
exposed_out=""
if [ -d .venv/exposed ]; then
  for l in .venv/exposed/*; do
    [ -L "$l" ] || continue
    case "$(readlink -f "$l" 2>/dev/null)" in "$RC2_ROOT"/*) ;; *) exposed_out+="$l->$(readlink "$l") ";; esac
  done
fi
assert_empty ".venv/exposed CLI symlinks resolve inside the repo" "points outside" "$exposed_out"

# ── 3. DOCTRINE — the system prompt. Present, ordered, byte-stable, general ──
echo
echo "[doctrine]"
missing=""
for n in 00-prime-directive 10-hunt-loop 20-research-and-dorking 30-interactive-and-tools \
         40-memory-and-state 50-subagents 60-reversing; do
  [ -s "doctrine/$n.md" ] || missing+="$n "
done
assert_empty "all 7 doctrine files present and non-empty" "missing" "$missing"

# Hardcoded cross-repo absolute paths are the cp-contamination bug: a doctrine
# copied from redcatN still points the agent back into redcatN. Doctrine must be
# REPO-AGNOSTIC (general) — relative paths / the symlinked scripts+reference dirs.
abs_paths="$(grep -rnE '/home/[^/]+/redcat[0-9]' doctrine/ 2>/dev/null)"
assert_empty "doctrine has no hardcoded cross-repo absolute paths" "hardcoded path" "$abs_paths"

# ── TRIPWIRE: failure-mode refs must stay epistemic, never drift into playbooks ──────
# Governed by 00-prime-directive. Two lines (see refs/README.md):
#  (1) a ref file must not name a target technique — CVE / msf module / per-service recipe;
#  (2) a mode detector must key on a REASONING signal, never on the target.
# Both pass trivially until refs/ + a MODES index exist; they bite the moment one drifts.
ref_tech=""
# scan refs/ and capabilities/ EXCEPT README (which legitimately names the banned things to forbid them)
while IFS= read -r f; do
  [ "$(basename "$f")" = "README.md" ] && continue
  hit="$(grep -nEi 'CVE-[0-9]{4}-[0-9]+|(^|[^a-z])(use +)?(exploit|auxiliary|payload)/|multi/handler|msfconsole' "$f" 2>/dev/null)"
  [ -n "$hit" ] && ref_tech+="$f: $(printf '%s' "$hit" | head -1)"$'\n'
done < <(find refs capabilities -maxdepth 1 -name '*.md' 2>/dev/null)
assert_empty "refs/ + capabilities/ name no target technique (CVE/msf/recipe)" "technique found" "$ref_tech"
# the capability library must exist with its manifest (the cross-run 'hands' store, #1)
if [ -s capabilities/INDEX.md ] && [ -s capabilities/README.md ]; then ok "capability library present (INDEX + README)"
else bad "capability library present (INDEX + README)"; fi

# detector allowlist = signals about the solver's own reasoning process (NOT the target)
SIGNALS='repeat|stall|inconclusive|untestable|journal|drift|breadth|decay|budget|ceiling|idle|surrender|grind|freeze|override|noprogress|no_progress|focus|consensus|repetition'
bad_detector="$(grep -rhniE 'detector:[[:space:]]*[a-z_]+' doctrine/ refs/ 2>/dev/null \
  | sed -E 's/.*detector:[[:space:]]*([a-z_]+).*/\1/I' \
  | grep -viE "^($SIGNALS)$" || true)"
assert_empty "every mode detector keys on a reasoning-signal (not the target)" "target-keyed detector" "$bad_detector"

# Source the launcher so we can exercise the real builders. Syntax already checked.
# shellcheck disable=SC1091
if . lib/bootstrap.sh 2>/tmp/_src.$$; then
  src_ok=1
else
  src_ok=0; bad "lib/bootstrap.sh sources cleanly" "$(tr '\n' ' ' </tmp/_src.$$)"
fi
rm -f /tmp/_src.$$

if [ "$src_ok" = 1 ]; then
  sp1="$(rc2_build_sysprompt)"; sp2="$(rc2_build_sysprompt)"
  bytes=${#sp1}
  if [ "$bytes" -gt 8000 ] && printf '%s' "$sp1" | head -1 | grep -q '^# 00'; then
    ok "system prompt builds, numeric order (starts at '# 00', ${bytes}B)"
  else
    bad "system prompt builds in numeric order" "bytes=$bytes first='$(printf '%s' "$sp1" | head -1)'"
  fi
  # byte-stability underpins the 1h prompt-cache: a non-deterministic prefix voids the cache every relaunch.
  if [ "$sp1" = "$sp2" ]; then ok "system prompt is byte-stable across builds (prompt-cache prefix)"
  else bad "system prompt is byte-stable" "two builds differ"; fi
fi

# ── 4. SCAFFOLD — the three living files must seed NON-EMPTY (empty-journal bug)
echo
echo "[scaffold]"
if [ "$src_ok" = 1 ]; then
  ( MACHINE_NAME="__selftest__" TARGET_IP="127.0.0.1" rc2_scaffold ) >/dev/null 2>&1
  SRUN="$RC2_ROOT/runs/__selftest__"
  trap 'rm -rf "$RC2_ROOT/runs/__selftest__" 2>/dev/null' EXIT
  seed_bad=""
  for f in worldmodel.md hypotheses.md journal.md ledger.json; do
    [ -s "$SRUN/$f" ] || seed_bad+="$f "
  done
  assert_empty "scaffold seeds worldmodel/hypotheses/journal/ledger non-empty" "empty/missing" "$seed_bad"
  # journal must carry a real START line, not just a header (the regression was a 1-line stub)
  if [ -s "$SRUN/journal.md" ] && grep -q 'START' "$SRUN/journal.md"; then
    ok "seeded journal has a START entry"
  else bad "seeded journal has a START entry" "journal: $(head -c80 "$SRUN/journal.md" 2>/dev/null)"; fi
  # ledger must be valid JSON with the keys the hook relies on
  if python3 -I -c "import json,sys; j=json.load(open('$SRUN/ledger.json')); assert 'current_hypothesis' in j and 'hypotheses' in j and 'negatives' in j" 2>/dev/null; then
    ok "seeded ledger.json is valid JSON with required keys"
  else bad "seeded ledger.json valid with required keys"; fi
  # the per-run hook must be registered and runnable
  if grep -q 'hook_log.sh' "$SRUN/.claude/settings.json" 2>/dev/null && [ -x "$RC2_ROOT/lib/hook_log.sh" ]; then
    ok "per-run hook registered in settings.json and executable"
  else bad "per-run hook registered and executable"; fi
else
  bad "scaffold checks (skipped — bootstrap did not source)"
fi

# ── 5. MODEL PIN — the real-time-cyber safety cap: opus MUST resolve to 4.8 ──
echo
echo "[model-pin]"
if [ "$src_ok" = 1 ]; then
  declare -A want=( [opus]=claude-opus-4-8 [claude-opus-5-5]=claude-opus-4-8
                    [claude-opus-4-8]=claude-opus-4-8 [sonnet]=sonnet [haiku]=haiku )
  pin_bad=""
  for m in "${!want[@]}"; do
    got="$(RC2_NO_PIN=0 rc2_pin_model "$m")"
    [ "$got" = "${want[$m]}" ] || pin_bad+="$m->$got(want ${want[$m]}) "
  done
  assert_empty "opus pinned to 4.8, sonnet/haiku pass through" "mispin" "$pin_bad"
  # agent frontmatter must never select an uncapped opus-5+ (the cap lives in env.sh, not the agents)
  bad_agent_model="$(grep -riE '^model:.*opus-[5-9]' .claude/agents/ 2>/dev/null)"
  assert_empty "no sub-agent frontmatter selects opus 5+" "uncapped agent model" "$bad_agent_model"
else
  bad "model-pin checks (skipped — bootstrap did not source)"
fi

# ── 6. AGENTS / SECRETS hygiene ──────────────────────────────────────────────
echo
echo "[agents/secrets]"
agent_bad=""
for a in exploit-dev recon-analyst researcher reverser verifier; do
  f=".claude/agents/$a.md"
  { [ -s "$f" ] && grep -q '^name:' "$f" && grep -q '^model:' "$f"; } || agent_bad+="$a "
done
assert_empty "all 5 sub-agents present with name+model frontmatter" "incomplete" "$agent_bad"
# .env must be gitignored and not tracked
if git ls-files --error-unmatch .env >/dev/null 2>&1; then
  bad ".env is NOT tracked by git" ".env is committed — secret leak"
else ok ".env is not tracked by git"; fi

# ── 7. VERIFY HAND — the mechanical prover must accept a real flag, reject decoys (#2) ──
echo
echo "[verify]"
if [ -x scripts/prove.sh ]; then
  good_flag="0123456789abcdef0123456789abcdef"
  decoy_md5="$(printf '%s' flag | md5sum 2>/dev/null | cut -d' ' -f1)"
  prove_bad=""
  scripts/prove.sh flag "$good_flag" >/dev/null 2>&1 || prove_bad+="rejected-real "
  scripts/prove.sh flag "not-a-flag" >/dev/null 2>&1 && prove_bad+="accepted-nonhex "
  [ -n "$decoy_md5" ] && { scripts/prove.sh flag "$decoy_md5" >/dev/null 2>&1 && prove_bad+="accepted-decoy "; }
  assert_empty "prove.sh flag: accepts a real 32-hex, rejects non-hex + md5 decoys" "misverdict" "$prove_bad"
else
  bad "scripts/prove.sh present and executable"
fi

# ── 8. STUCK-DEBATE — the synchronous critic↔solver dialogue wiring ──────────
echo
echo "[debate]"
if [ "$src_ok" = 1 ]; then
  # the hook's allow/block decision table (dependency-free helper in guard_lib.sh)
  dbg=""
  rc2_debate_allowed solver Read ""                       || dbg+="solver-Read-blocked "
  rc2_debate_allowed solver WebSearch ""                  || dbg+="solver-WebSearch-blocked "
  rc2_debate_allowed solver Bash ""                       && dbg+="solver-Bash-allowed "
  rc2_debate_allowed solver Task ""                       && dbg+="solver-Task-allowed "
  rc2_debate_allowed solver Write "/r/logs/.debate_reply" || dbg+="solver-reply-write-blocked "
  rc2_debate_allowed solver Edit  "/r/hypotheses.md"      || dbg+="solver-board-edit-blocked "
  rc2_debate_allowed solver Write "/r/exploit/x.py"       && dbg+="solver-exploit-write-allowed "
  rc2_debate_allowed critic Read ""                       || dbg+="critic-Read-blocked "
  rc2_debate_allowed critic Write "/r/logs/.debate_reply" && dbg+="critic-write-allowed "
  rc2_debate_allowed critic Bash ""                       && dbg+="critic-Bash-allowed "
  assert_empty "debate allow/block table: solver reads+research+reply, critic read-only, target actions blocked" "misgate" "$dbg"
  # no open debate ⇒ no turn ⇒ the hook gate is a no-op (the safety invariant: the mechanism is inert when off)
  dtmp="$(mktemp -d)"; mkdir -p "$dtmp/logs"
  if [ -z "$(rc2_debate_turn "$dtmp")" ] && ! rc2_debate_active "$dtmp"; then ok "no .debate_turn ⇒ debate inactive (hook gate inert when off)"
  else bad "debate inactive with no .debate_turn file"; fi
  printf 'solver' > "$dtmp/logs/.debate_turn"
  [ "$(rc2_debate_turn "$dtmp")" = "solver" ] && ok "a .debate_turn file activates the gate" || bad "a .debate_turn file activates the gate"
  rm -rf "$dtmp"
else
  bad "debate helper checks (skipped — bootstrap did not source)"
fi
# the hook must invoke the gate in BOTH phases (pre block + post turn-flip)
if grep -q 'rc2_debate_gate' lib/hook_log.sh && grep -q '\.debate_turn' lib/hook_log.sh; then
  ok "hook wires the debate gate (pre-block + post turn-flip)"
else bad "hook wires the debate gate"; fi
# the shared driver module must carry open→turn→close + the atomic ownership claim (race prevention)
if [ -s scripts/lib/debate.sh ]; then
  ddrv=""
  for fn in rc2_debate_claim rc2_debate_parse rc2_debate_open_if_stuck rc2_debate_service rc2_debate_finish; do
    grep -q "^$fn()" scripts/lib/debate.sh || ddrv+="$fn "
  done
  assert_empty "scripts/lib/debate.sh carries the shared driver (claim→open→turn→close)" "missing fn" "$ddrv"
else bad "scripts/lib/debate.sh present"; fi
# BOTH sidecars must configure the shared driver for their role (so either can be the first initiator)
rolecfg=""
grep -q 'RC2_DBG_ROLE="oversee"' scripts/oversee.sh || rolecfg+="oversee-role "
grep -q 'rc2_sidecar_stuck_check' scripts/oversee.sh || rolecfg+="oversee-stuckcheck "
grep -q 'RC2_DBG_ROLE="auditor"' scripts/auditor.sh || rolecfg+="auditor-role "
grep -q 'rc2_debate_open_if_stuck' scripts/auditor.sh || rolecfg+="auditor-open "
assert_empty "oversee + auditor each configure the shared driver for their role" "missing" "$rolecfg"
# RACE PREVENTION: the open is an ATOMIC ownership claim that records BOTH roles (owner + who it calls)
if grep -q 'set -o noclobber' scripts/lib/debate.sh \
   && grep -q 'owner:$o' scripts/lib/debate.sh && grep -q 'with:"solver"' scripts/lib/debate.sh; then
  ok "debate open atomically claims ownership + names both roles (owner → solver)"
else bad "debate open is an atomic, role-naming ownership claim"; fi
# and prove the claim is actually atomic: two concurrent claims on one run dir → exactly one wins
if [ "$src_ok" = 1 ]; then
  ( . scripts/lib/debate.sh 2>/dev/null
    d="$(mktemp -d)"; mkdir -p "$d/logs"
    rc2_debate_claim "$d" oversee; a=$?
    rc2_debate_claim "$d" auditor; b=$?   # second claim must FAIL (owner already set)
    own="$(rc2_debate_owner "$d")"; rm -rf "$d"
    [ "$a" -eq 0 ] && [ "$b" -ne 0 ] && [ "$own" = "oversee" ]
  ) && ok "ownership claim is atomic (first wins, second backs off — no two-critic race)" \
    || bad "ownership claim is atomic"
fi
# the debate-aware shared mainloop services turns + offers the stuck-check hook
if grep -q 'rc2_debate_service' scripts/lib/reviewer_loop.sh && grep -q 'rc2_sidecar_stuck_check' scripts/lib/reviewer_loop.sh; then
  ok "shared mainloop is debate-aware (services turns + stuck-check hook)"
else bad "shared mainloop is debate-aware"; fi
# JUDGE GATE: the fixed thresholds are only a prefilter — a context-aware critic can decline (DEBATE: PASS).
# oversee's opening lead-in must offer PASS; rc2_debate_parse must recognize it; on PASS the open must bail.
if grep -qi 'DEBATE: PASS' scripts/oversee.sh && grep -q 'pass' scripts/lib/debate.sh; then
  ok "stuck prefilter is judge-gated (critic may DEBATE: PASS a false positive)"
else bad "stuck prefilter is judge-gated (DEBATE: PASS)"; fi
if [ "$src_ok" = 1 ]; then
  pass_ok="$(
    . scripts/lib/debate.sh 2>/dev/null
    rc2_reviewer_failed(){ return 1; }   # stub: never an error, so parse evaluates the verdict
    p="$(rc2_debate_parse "$(printf 'DEBATE: PASS\nTO SOLVER: still enumerating a deep surface')")"
    printf '%s' "${p%%$'\t'*}"
  )"
  [ "$pass_ok" = "pass" ] && ok "rc2_debate_parse recognizes the PASS gate verdict" || bad "rc2_debate_parse recognizes PASS" "got '$pass_ok'"
fi
# the round cap is wired to the env knob (default 6), not hardcoded
if grep -q 'RC2_DEBATE_MAX_ROUNDS' scripts/oversee.sh && grep -q 'RC2_DEBATE_MAX_ROUNDS' lib/env.sh; then
  ok "debate round cap reads RC2_DEBATE_MAX_ROUNDS (env-tunable)"
else bad "debate round cap is env-tunable"; fi
# env.sh must export the debate knobs so the per-call hook + sidecar inherit them
denv="$(for v in RC2_DEBATE RC2_DEBATE_MAX_ROUNDS RC2_DEBATE_POLL RC2_DEBATE_STALL_T RC2_DEBATE_SURFACE_N RC2_DEBATE_DROUGHT_M; do
          grep -qE "export .*$v|$v " lib/env.sh || echo "$v"; done)"
assert_empty "env.sh defines+exports the debate knobs" "missing knob" "$denv"
# the solver-side protocol must be in the doctrine (both the loop rule and the memory channel)
ddoc=""
grep -qi 'stuck-debate'   doctrine/10-hunt-loop.md     || ddoc+="10-loop "
grep -q  '.debate_reply'  doctrine/10-hunt-loop.md     || ddoc+="10-reply-channel "
grep -q  'debate.md'      doctrine/40-memory-and-state.md || ddoc+="40-transcript "
assert_empty "doctrine documents the debate protocol (solver behavior + reply channel)" "missing doc" "$ddoc"
# launch must clear stale debate state (a mid-debate crash must not block a resume)
if grep -q '.debate_turn' hunt; then ok "hunt clears stale debate state at launch"
else bad "hunt clears stale debate state at launch"; fi

# ── 9. WIN-DISCIPLINE + RESEARCH-FLOOR (A: false-root guard · D: stop-on-solve · B: research drought) ──
echo
echo "[win-discipline]"
# A — the flag-submit integrity guard: user.txt and root.txt are never equal; a value matching the OTHER
# kind must be refused (a mis-written flags.txt would otherwise be accepted by the API as a false win).
if grep -q 'rc2_flag_value user\|rc2_flag_value root' lib/htb.sh && grep -qi 'REFUSE' lib/htb.sh; then
  ok "flag submit refuses root==user / user==root (A: false-root guard present)"
else bad "flag submit has the user!=root integrity guard"; fi
# functional: a flags.txt with root==user must NOT reach the API (guard returns before htb_submit_flag)
if [ "$src_ok" = 1 ]; then
  fr="$(
    d="$(mktemp -d)"; mkdir -p "$d/logs"
    printf 'user=%s\nroot=%s\n' "0123456789abcdef0123456789abcdef" "0123456789abcdef0123456789abcdef" > "$d/flags.txt"
    machine_id=1 HTB_TOKEN=x
    htb_submit_flag(){ echo "REACHED_API"; }   # stub: if the guard fails, this fires
    _rc2_submit_flag "$d" root "0123456789abcdef0123456789abcdef" 2>/dev/null
    grep -q REACHED_API "$d/logs/flag_submit.log" 2>/dev/null && echo LEAK || echo blocked
    rm -rf "$d"
  )"
  [ "$fr" = "blocked" ] && ok "false-root (root==user) is blocked before the API (functional)" || bad "false-root blocked before the API" "got: $fr"
fi
# D — stop-on-solve: the attempt guard terminates a solved-but-spinning solver so the loop can teardown
if grep -q 'rc2_solved "\$RUNDIR"' lib/run.sh && grep -qi 'run COMPLETE' lib/run.sh; then
  ok "attempt guard stops the solver on a verified solve (D: no post-solve spin)"
else bad "attempt guard stops on verified solve (D)"; fi
# B-2-1 — research-drought FLOOR: trips on actions-since-any-research, not only failures-since-search
if grep -q 'RC2_DEBATE_DROUGHT_FLOOR' scripts/oversee.sh && grep -q 'research-drought(floor)' scripts/oversee.sh \
   && grep -q 'RC2_DEBATE_DROUGHT_FLOOR' lib/env.sh; then
  ok "S3 has the research-drought FLOOR path (B: catches progress-on-unverified-prior)"
else bad "S3 research-drought FLOOR path wired"; fi
# B-1차 — doctrine requires verifying a pivotal prior-derived (inferred) claim before building on it
if grep -qi 'pivotal claim from prior' doctrine/10-hunt-loop.md && grep -qi 'one research action' doctrine/10-hunt-loop.md; then
  ok "doctrine requires verifying pivotal inferred claims before building on them (B-1차)"
else bad "doctrine: verify pivotal inferred claims"; fi

# ── SUMMARY ───────────────────────────────────────────────────────────────────
echo
if [ "$FAIL" -eq 0 ]; then
  printf '%sall %d checks passed%s\n' "$G" "$PASS" "$N"
  exit 0
else
  printf '%s%d passed, %d FAILED%s: %s\n' "$R" "$PASS" "$FAIL" "$N" "${FAILED_NAMES[*]}"
  exit 1
fi
