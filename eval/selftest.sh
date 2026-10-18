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
if [ -d refs ]; then
  # scan refs/*.md EXCEPT README (which legitimately names the banned things to forbid them)
  while IFS= read -r f; do
    [ "$(basename "$f")" = "README.md" ] && continue
    hit="$(grep -nEi 'CVE-[0-9]{4}-[0-9]+|(^|[^a-z])(use +)?(exploit|auxiliary|payload)/|multi/handler|msfconsole' "$f" 2>/dev/null)"
    [ -n "$hit" ] && ref_tech+="$f: $(printf '%s' "$hit" | head -1)"$'\n'
  done < <(find refs -maxdepth 1 -name '*.md' 2>/dev/null)
fi
assert_empty "refs/ name no target technique (CVE/msf/recipe)" "technique in a ref" "$ref_tech"

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

# ── SUMMARY ───────────────────────────────────────────────────────────────────
echo
if [ "$FAIL" -eq 0 ]; then
  printf '%sall %d checks passed%s\n' "$G" "$PASS" "$N"
  exit 0
else
  printf '%s%d passed, %d FAILED%s: %s\n' "$R" "$PASS" "$FAIL" "$N" "${FAILED_NAMES[*]}"
  exit 1
fi
