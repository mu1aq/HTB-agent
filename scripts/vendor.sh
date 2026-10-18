#!/usr/bin/env bash
# =============================================================================
#  vendor.sh — make the external DATA resources reachable from INSIDE this folder.
#
#  The repo's only runtime data deps are wordlists/refs that live in a shared tree
#  (~/files_etc): SecLists (~2G), PayloadsAllTheThings, GTFOBins. env.sh / rag.sh /
#  install_tools.sh now PREFER an in-folder vendor/ copy and only fall back to the
#  shared tree — so populating vendor/ is what makes a hunt run folder-local.
#
#    scripts/vendor.sh              # symlink each resource into vendor/ (instant, default)
#    scripts/vendor.sh --copy       # hard-copy into vendor/ (truly self-contained; SecLists is ~2G)
#    scripts/vendor.sh --status     # show what is linked/copied/missing
#    SRC=/path scripts/vendor.sh    # pull from a different shared tree (default ~/files_etc)
#
#  NOTE: vendor/ is gitignored (data, often huge) — this is local setup, not committed.
#  A symlink makes the repo SELF-REFERENTIAL (all paths in-folder) but still points at the
#  shared tree; --copy makes the folder PORTABLE (survives a move/copy) at the cost of size.
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SRC:-$HOME/files_etc}"
VENDOR="$ROOT/vendor"
RES=(SecLists PayloadsAllTheThings GTFOBins)
mode="link"; [ "${1:-}" = "--copy" ] && mode="copy"

mkdir -p "$VENDOR"

if [ "${1:-}" = "--status" ]; then
  for r in "${RES[@]}"; do
    d="$VENDOR/$r"
    if   [ -L "$d" ]; then printf '  %-22s symlink -> %s\n' "$r" "$(readlink "$d")"
    elif [ -d "$d" ]; then printf '  %-22s copied  (%s)\n' "$r" "$(du -sh "$d" 2>/dev/null | cut -f1)"
    else                   printf '  %-22s MISSING (falls back to %s/%s)\n' "$r" "$SRC" "$r"; fi
  done
  exit 0
fi

for r in "${RES[@]}"; do
  s="$SRC/$r"; d="$VENDOR/$r"
  if [ ! -e "$s" ]; then echo "[vendor] skip $r — not found at $s" >&2; continue; fi
  [ -e "$d" ] || [ -L "$d" ] && rm -rf "$d"
  if [ "$mode" = copy ]; then
    echo "[vendor] copying $r (this can be large) ..."
    cp -a "$s" "$d"
  else
    ln -s "$s" "$d"
    echo "[vendor] linked $r -> $s"
  fi
done
echo "[vendor] done. env.sh/rag.sh now resolve these from $VENDOR first."
