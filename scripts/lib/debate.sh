#!/usr/bin/env bash
# =============================================================================
#  scripts/lib/debate.sh — the SHARED stuck-debate driver, sourced by BOTH reviewer
#  sidecars (oversee + auditor) via reviewer_loop.sh. A debate is a synchronous,
#  turn-based critic↔solver dialogue, opened only when the solver is measurably
#  stuck; the hook (lib/hook_log.sh) does the blocking, this does the thinking.
#
#  Why this is shared (and ownership-tagged): EITHER sidecar may be the first to
#  request a debate — oversee on a strategy signal (S1/S2/S3), the auditor on an
#  evidence-quality signal (S4). To avoid a race where two critics both try to open
#  or both try to drive the same debate, opening is an ATOMIC OWNERSHIP CLAIM: the
#  first writer of logs/.debate_owner wins and becomes the sole critic; it records
#  WHICH role it is and that it is calling the "solver". Only the OWNER drives the
#  turns; the loser backs off (the auditor instead folds its finding into the open
#  debate's transcript, see auditor.sh). One debate, one owner, named roles.
#
#  The caller parameterizes per-role via globals set before the loop runs:
#    RC2_DBG_ON        1 if this sidecar may open/drive debates (else inert)
#    RC2_DBG_ROLE      this sidecar's role name — "oversee" | "auditor"
#    RC2_DBG_MODEL     the critic model for this sidecar
#    RC2_DBG_SYS       the system-prompt file (OVERSEER.md / AUDITOR.md)
#    RC2_DBG_LEADIN_OPEN / RC2_DBG_LEADIN_TURN   the reviewer lead-ins
#    RC2_DBG_DIGEST_FN name of the function that prints the debate digest on stdout
#    RC2_DBG_HIST      this sidecar's history jsonl
#    RC2_DBG_MAX       round cap (RC2_DEBATE_MAX_ROUNDS)
#    RC2_DBG_POLL      poll cadence while a debate is open (RC2_DEBATE_POLL)
#  Needs (from common.sh / guard_lib.sh / reviewer_loop.sh, all already sourced):
#    rc2_debate_active, rc2_debate_turn, rc2_debate_owner, rc2_json_update, rc2_utc,
#    rc2_write_supervisor, rc2_reviewer_call, rc2_reviewer_failed, $RUNDIR, colors.
# =============================================================================

# rc2_debate_claim <rundir> <role> — ATOMIC ownership claim. The ( set -o noclobber; … > file ) write
# fails if logs/.debate_owner already exists, so exactly one of two concurrent openers wins the race.
# Returns 0 if THIS role now owns the debate, non-zero if someone already owns it (or on any error).
rc2_debate_claim() {
  local f="${1:-.}/logs/.debate_owner"
  ( set -o noclobber; printf '%s' "$2" > "$f" ) 2>/dev/null
}

# rc2_dbg_i_own <rundir> — true(0) iff THIS sidecar's RC2_DBG_ROLE owns the current debate.
rc2_dbg_i_own() { [ "$(rc2_debate_owner "${1:-$RUNDIR}")" = "${RC2_DBG_ROLE:-}" ]; }

# rc2_debate_parse <verdict> — echo "<pass|continue|resolved|error>\t<TO SOLVER text>". A cyber/API/empty
# error in the text is surfaced verbatim as "error" (never parsed into a bogus decision). PASS is the
# OPENING-turn gate: the critic, reading the actual evidence, judged the cheap prefilter a false positive
# (the solver is NOT genuinely stuck — legitimately deep work) and declined to open. TO SOLVER may be multi-line.
rc2_debate_parse() {
  local v="$1" st msg
  if rc2_reviewer_failed 0 "$v"; then printf 'error\t%s' "$v"; return 0; fi
  st="$(printf '%s' "$v" | grep -oiE 'DEBATE:[[:space:]]*(pass|continue|resolved)' | head -1 | grep -oiE 'pass|continue|resolved' | tr 'A-Z' 'a-z')"; st="${st:-continue}"
  msg="$(printf '%s\n' "$v" | awk 'BEGIN{p=0} /^[Tt][Oo][[:space:]][Ss][Oo][Ll][Vv][Ee][Rr]:/{p=1; sub(/^[^:]*:[[:space:]]*/,""); print; next} p{print}')"
  [ -n "$msg" ] || msg="$v"
  printf '%s\t%s' "$st" "$msg"
}

# rc2_debate_call <leadin> — one debate reviewer pass: the role's digest on stdin, verdict on stdout.
rc2_debate_call() { "${RC2_DBG_DIGEST_FN}" | rc2_reviewer_call "$RC2_DBG_MODEL" "$RC2_DBG_SYS" "$1"; }

# rc2_debate_open_if_stuck <signal> <seed> — open a debate AS RC2_DBG_ROLE, calling the solver, IF this
# sidecar may (RC2_DBG_ON), none is active, and the ownership claim wins. The claim is what makes this
# race-free: a simultaneous opener loses the noclobber and returns here harmlessly. .debate_turn is written
# LAST (after the message exists) so the hook never blocks the solver before there is something to show it.
rc2_debate_open_if_stuck() {
  [ "${RC2_DBG_ON:-0}" = "1" ] || return 0
  rc2_debate_active "$RUNDIR" && return 0
  local sig="$1" seed="$2" acct="$RUNDIR/logs/accounting.json" exp verdict parsed st msg
  rc2_debate_claim "$RUNDIR" "$RC2_DBG_ROLE" || return 0   # lost the race (or a stale owner exists) — back off
  exp="$(jq -r '.global.experiments // 0' "$acct" 2>/dev/null)"; exp="${exp:-0}"
  # record BOTH roles in the request: owner (the critic that called) + with (who it called). No ambiguity.
  rc2_json_update "$acct" '.debate={active:true, round:1, owner:$o, with:"solver", signal:$s, seed:$e, injected_round:-1, errors:0, opened_exp:($x|tonumber), opened_utc:(now|todate)}' \
     --arg o "$RC2_DBG_ROLE" --arg s "$sig" --arg e "$seed" --argjson x "$exp"
  echo "${r:-}[$RC2_DBG_ROLE] prefilter tripped ($sig) — asking the critic to judge (then open if truly stuck): ${seed}${n:-}"
  # THE JUDGE, folded into the opening call. The cheap prefilter (fixed thresholds) only decided this was
  # WORTH ASKING; the critic reads the real evidence and either declines (DEBATE: PASS — a false positive,
  # e.g. legitimately deep work on a complex surface) or opens with a critique. One opus call gates AND opens.
  verdict="$(rc2_debate_call "$RC2_DBG_LEADIN_OPEN")"
  parsed="$(rc2_debate_parse "$verdict")"; st="${parsed%%$'\t'*}"; msg="${parsed#*$'\t'}"
  if [ "$st" = "error" ] || [ "$st" = "pass" ]; then
    # error → retry later; pass → the critic judged it NOT stuck. Either way: don't open, release the claim,
    # and set the cooldown so the prefilter doesn't re-ask the critic every tick while it stays tripped.
    if [ "$st" = "pass" ]; then echo "${d:-}[$RC2_DBG_ROLE] critic judged NOT stuck (PASS) — prefilter was a false positive; cooling down.${n:-}"
    else echo "${y:-}[$RC2_DBG_ROLE] debate-open reviewer call failed — NOT opening (will retry later).${n:-}"; fi
    rc2_json_update "$acct" '.debate.active=false | .debate.last_close_exp=($x|tonumber) | .debate.outcome=$o' --argjson x "$exp" --arg o "$st"
    rm -f "$RUNDIR/logs/.debate_owner" 2>/dev/null   # release the claim so a later attempt can re-open
    return 0
  fi
  { printf '\n==== DEBATE OPENED %s · %s → solver · signal=%s ====\n%s\n\n[%s · round 1]\n%s\n' \
      "$(rc2_utc)" "$RC2_DBG_ROLE" "$sig" "$seed" "$RC2_DBG_ROLE" "$msg"; } >> "$RUNDIR/logs/debate.md" 2>/dev/null
  printf '%s' "$msg" > "$RUNDIR/logs/.debate_msg" 2>/dev/null
  : > "$RUNDIR/logs/.debate_reply" 2>/dev/null
  jq -cn --arg ts "$(rc2_utc)" --arg sig "$sig" --arg seed "$seed" --arg m "$msg" --arg role "$RC2_DBG_ROLE" \
     '{ts:$ts, event:"debate-open", owner:$role, with:"solver", round:1, signal:$sig, seed:$seed, to_solver:$m}' >> "$RC2_DBG_HIST" 2>/dev/null
  printf 'solver' > "$RUNDIR/logs/.debate_turn" 2>/dev/null   # LAST: now the hook blocks the solver
  echo "   ${r:-}debate OPEN${n:-} → $RC2_DBG_ROLE → solver, round 1 (solver blocked until resolved)"
}

# rc2_debate_service — one debate step, called each loop tick while a debate is active. Drives a turn ONLY
# if THIS sidecar owns the debate AND it is the critic's turn; otherwise a no-op (a non-owner never touches
# the turn protocol — that is the race guarantee). Reads the solver's reply, decides CONTINUE vs RESOLVE,
# presses on (new round) or closes. Round cap forces a decision; reviewer errors are bounded then forced.
rc2_debate_service() {
  rc2_dbg_i_own "$RUNDIR" || return 0
  [ "$(rc2_debate_turn "$RUNDIR")" = "critic" ] || return 0
  local acct="$RUNDIR/logs/accounting.json" round verdict parsed st msg errs
  round="$(jq -r '.debate.round // 1' "$acct" 2>/dev/null)"; round="${round:-1}"
  if [ -s "$RUNDIR/logs/.debate_reply" ]; then
    { printf '\n[solver · round %s]\n%s\n' "$round" "$(cat "$RUNDIR/logs/.debate_reply" 2>/dev/null)"; } >> "$RUNDIR/logs/debate.md" 2>/dev/null
  fi
  echo "${c:-}[$RC2_DBG_ROLE]${n:-} debate round $round — reviewing solver reply (${RC2_DBG_MODEL}) ..."
  verdict="$(rc2_debate_call "$RC2_DBG_LEADIN_TURN")"
  parsed="$(rc2_debate_parse "$verdict")"; st="${parsed%%$'\t'*}"; msg="${parsed#*$'\t'}"
  if [ "$st" = "error" ]; then
    errs="$(jq -r '.debate.errors // 0' "$acct" 2>/dev/null)"; errs=$((${errs:-0}+1))
    rc2_json_update "$acct" '.debate.errors=$e' --argjson e "$errs"
    if [ "$errs" -ge 3 ]; then
      rc2_debate_finish forced "Critic unavailable after $errs failed reviews — follow the LAST critique in logs/debate.md, pick the single highest-value UNTESTED lever on the live surface, and research it (web) before retrying anything already tried."
    else
      echo "${y:-}   debate reviewer call failed ($errs/3) — holding solver, retry next poll${n:-}"
    fi
    return 0
  fi
  jq -cn --arg ts "$(rc2_utc)" --arg st "$st" --arg m "$msg" --argjson r "$round" --arg role "$RC2_DBG_ROLE" \
     '{ts:$ts, event:"debate-turn", owner:$role, round:$r, decision:$st, to_solver:$m}' >> "$RC2_DBG_HIST" 2>/dev/null
  if [ "$st" = "resolved" ]; then rc2_debate_finish resolved "$msg"; return 0; fi
  if [ "$round" -ge "${RC2_DBG_MAX:-6}" ] 2>/dev/null; then
    rc2_debate_finish forced "Round cap (${RC2_DBG_MAX:-6}) reached without agreement. FINAL DECISION (operator priority): $msg"; return 0
  fi
  round=$((round+1))
  rc2_json_update "$acct" '.debate.round=$r | .debate.injected_round=-1 | .debate.errors=0' --argjson r "$round"
  { printf '\n[%s · round %s]\n%s\n' "$RC2_DBG_ROLE" "$round" "$msg"; } >> "$RUNDIR/logs/debate.md" 2>/dev/null
  printf '%s' "$msg" > "$RUNDIR/logs/.debate_msg" 2>/dev/null
  : > "$RUNDIR/logs/.debate_reply" 2>/dev/null
  printf 'solver' > "$RUNDIR/logs/.debate_turn" 2>/dev/null
  echo "   ${y:-}debate continues${n:-} → round $round, solver's turn"
}

# rc2_debate_finish <outcome> <final-message> — end the debate: durable transcript marker, a SUPERVISOR_TICK
# carrying the resolution (persists in the normal channel + binds the solver), release ALL debate files
# (incl. the ownership claim, so the next debate can be claimed), and set the cooldown anchor.
rc2_debate_finish() {
  local outcome="$1" final="$2" acct="$RUNDIR/logs/accounting.json" exp round tag col
  exp="$(jq -r '.global.experiments // 0' "$acct" 2>/dev/null)"; exp="${exp:-0}"
  round="$(jq -r '.debate.round // 1' "$acct" 2>/dev/null)"; round="${round:-1}"
  tag="RESOLVED"; [ "$outcome" = "forced" ] && tag="FORCED DECISION"
  { printf '\n[%s · %s · round %s · %s]\n%s\n==== DEBATE CLOSED ====\n' "$RC2_DBG_ROLE" "$tag" "$round" "$(rc2_utc)" "$final"; } >> "$RUNDIR/logs/debate.md" 2>/dev/null
  rc2_write_supervisor "$RUNDIR" "debate-$outcome($RC2_DBG_ROLE)" "$(printf '%s\n\n%s\n%s\n%s\n%s\n%s' \
    "_stuck-debate with the $RC2_DBG_ROLE critic closed after $round round(s) — outcome: $outcome_" \
    "STATUS: rabbit-hole" \
    "FOCUS: debate-$outcome" \
    "READ: an operator-level debate ($RC2_DBG_ROLE → you) just concluded; its decision overrides your prior momentum." \
    "STOP: whatever you were grinding when the debate opened." \
    "DO NEXT: $final")" >/dev/null
  jq -cn --arg ts "$(rc2_utc)" --arg o "$outcome" --arg f "$final" --argjson r "$round" --arg role "$RC2_DBG_ROLE" \
     '{ts:$ts, event:"debate-close", owner:$role, round:$r, outcome:$o, to_solver:$f}' >> "$RC2_DBG_HIST" 2>/dev/null
  rc2_json_update "$acct" '.debate.active=false | .debate.last_close_exp=($x|tonumber) | .debate.outcome=$o | .debate.closed_utc=(now|todate)' \
     --argjson x "$exp" --arg o "$outcome"
  rm -f "$RUNDIR/logs/.debate_turn" "$RUNDIR/logs/.debate_msg" "$RUNDIR/logs/.debate_reply" "$RUNDIR/logs/.debate_owner" 2>/dev/null
  col="$g"; [ "$outcome" = "forced" ] && col="$r"
  echo "   ${col}debate CLOSED${n:-} ($outcome, $round round(s)) → wrote SUPERVISOR_TICK; solver unblocked"
}
