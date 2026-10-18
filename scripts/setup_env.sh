#!/usr/bin/env bash
# =============================================================================
#  setup_env.sh — one-time project environment via uv. Run this FIRST, before hunts.
#  Creates a pinned-Python .venv with the interactive tooling redcat2 drives (pwncat-cs, pexpect).
#  WHY uv + a pinned venv: the system pipx pwncat-cs was broken (ModuleNotFoundError: pkg_resources).
#  Root cause chased down: pwncat-cs 0.5.4 needs stdlib `distutils` (removed in Python 3.12) AND
#  `pkg_resources` (dropped by setuptools>=81 and by Python 3.14's bundled setuptools). The reproducible
#  fix = a uv venv on **Python 3.11** (has distutils) with **setuptools<81** (still ships pkg_resources).
#  Idempotent; self-tests pwncat-cs so a broken env is caught HERE, not mid-hunt (5h window).
#    scripts/setup_env.sh
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

if ! command -v uv >/dev/null 2>&1; then
  echo "[setup] uv not found. Install it first:  curl -LsSf https://astral.sh/uv/install.sh | sh"
  exit 1
fi

echo "[setup] creating .venv (uv, Python 3.11) ..."
uv venv --python 3.11 .venv --clear    # uv fetches a managed 3.11 if the host lacks one; --clear = reproducible

echo "[setup] installing interactive tooling (pwncat-cs, pexpect, setuptools<81, requests) ..."
VIRTUAL_ENV="$ROOT/.venv" uv pip install pwncat-cs pexpect requests 'setuptools<81'

# Expose ONLY the CLI tools we want on PATH (pwncat-cs), via a dedicated dir — NOT the whole .venv/bin,
# which would put the venv's `python`/`pip` ahead of system python and break the solver's own scripts
# (boto3/impacket/pwntools live in system python, not this minimal venv). lib/env.sh prepends .venv/exposed.
echo "[setup] exposing CLI tools (pwncat-cs) without shadowing system python ..."
mkdir -p "$ROOT/.venv/exposed"
rm -f "$ROOT/.venv/exposed/pwncat-cs"
ln -s "$ROOT/.venv/bin/pwncat-cs" "$ROOT/.venv/exposed/pwncat-cs"

echo "[setup] self-test: pwncat-cs imports?"
if "$ROOT/.venv/bin/pwncat-cs" --version >/dev/null 2>&1; then
  echo "[setup] OK — pwncat-cs runs ($("$ROOT/.venv/bin/pwncat-cs" --version 2>&1 | head -1))"
else
  echo "[setup] WARN — pwncat-cs still not runnable; the doctrine falls back to nc + manual PTY, so hunts still work."
fi
echo "[setup] done. hunt prepends $ROOT/.venv/bin to PATH automatically (lib/env.sh)."
