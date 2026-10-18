#!/usr/bin/env bash
# =============================================================================
#  prove.sh — the mechanical verification hand (#2). Makes the doctrine's VERIFY
#  step deterministic and reusable so a win is PROVEN, not assumed — the common
#  loss being "thought it worked / thought it was the flag" (false-verify).
#
#  This is "hands", not a playbook: it executes a mechanical CHECK and returns a
#  verdict; it never chooses a vector. Deterministic + general (no target coupling).
#
#    prove.sh flag <value>             # is this a real flag, or an echo/decoy? REAL|SUSPECT
#    prove.sh shell <tmux_session>     # does this session really give me code exec + who am I?
#    prove.sh --help
#  Exit: 0 = proven/REAL, 1 = SUSPECT/unproven, 2 = usage.
# =============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLAG_RE='^[0-9a-fA-F]{32}$'
G=$'\033[32m'; R=$'\033[31m'; N=$'\033[0m'; [ -t 1 ] || { G=; R=; N=; }
real(){ printf '%sREAL%s    %s\n' "$G" "$N" "$1"; exit 0; }
suspect(){ printf '%sSUSPECT%s %s\n' "$R" "$N" "$1"; exit 1; }

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  flag)
    v="$(printf '%s' "${1:-}" | tr -d '[:space:]')"
    [ -n "$v" ] || suspect "empty"
    printf '%s' "$v" | grep -qE "$FLAG_RE" || suspect "not a 32-hex HTB flag (len=${#v}) — an echo/path/partial read?"
    lc="$(printf '%s' "$v" | tr 'A-Z' 'a-z')"
    # all-identical or trivially patterned hex = almost certainly a placeholder/decoy
    [ "$(printf '%s' "$lc" | fold -w1 | sort -u | tr -d '\n' | wc -c)" -le 1 ] && suspect "all-identical chars — a placeholder, not a real flag"
    # md5 of common decoy strings (deterministic decoy catch)
    if command -v md5sum >/dev/null 2>&1; then
      for s in flag test example password admin changeme user root; do
        [ "$lc" = "$(printf '%s' "$s" | md5sum | cut -d' ' -f1)" ] && suspect "md5('$s') — a canned decoy value"
      done
    fi
    real "32-hex, no decoy signature. (Still confirm PROVENANCE: it must come from user.txt/root.txt on the target, not another file.)"
    ;;
  shell)
    sess="${1:-}"; [ -n "$sess" ] || { echo "usage: prove.sh shell <tmux_session>" >&2; exit 2; }
    command -v tmux >/dev/null 2>&1 || { echo "tmux not found" >&2; exit 2; }
    tmux has-session -t "$sess" 2>/dev/null || suspect "no tmux session '$sess' — nothing to prove"
    nonce="RC2PROVE_$RANDOM$RANDOM"
    tmux send-keys -t "$sess" "echo $nonce; id; whoami; hostname; uname -a 2>/dev/null || ver" Enter
    sleep 2
    out="$(tmux capture-pane -p -t "$sess" 2>/dev/null)"
    printf '%s' "$out" | grep -q "$nonce" || suspect "nonce did not round-trip — the session is not executing commands (dead/blocked shell)"
    ident="$(printf '%s' "$out" | grep -aE 'uid=|^[A-Za-z0-9_\\.-]+$' | tail -3 | tr '\n' ' ')"
    real "session executes code. identity: ${ident:-<capture it manually>}  (now VERIFY this identity is the privilege you claimed)"
    ;;
  -h|--help|"")
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2 ;;
  *) echo "unknown: $cmd (try --help)" >&2; exit 2 ;;
esac
