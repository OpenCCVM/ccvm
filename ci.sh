#!/usr/bin/env bash
# Local CI — runs the SAME checks as .github/workflows/flake-check.yml by pulling
# each step's `run:` script straight from that workflow, so the command list lives
# in exactly one place. Run before every commit.
#
# Safety: these `run:` scripts execute as your user with NO sandbox. If the workflow
# differs from origin/main (an unreviewed/unexpected change), the commands are shown
# and confirmation is required first — a silent edit to .github can't run behind your
# back. (A compromised origin/main is out of scope: it auto-deploys the docs site to
# GitHub Pages anyway.)
#
# `--inputs-from .` resolves every `nixpkgs#tool` against this flake's locked
# nixpkgs, so the tools are hash-pinned to flake.lock (no unpinned registry fetch).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

workflow=.github/workflows/flake-check.yml

steps=$(nix run --inputs-from . nixpkgs#yq -- -r \
  '.jobs.check.steps[] | select(.run) | "echo; echo \"» \(.name)\"\n\(.run)"' \
  "$workflow")

# Gate: if the workflow deviates from the trusted remote, show what runs and confirm.
ref=origin/main
if git rev-parse --verify --quiet "$ref" >/dev/null &&
  ! git diff --quiet "$ref" -- "$workflow"; then
  echo "⚠  $workflow differs from $ref — these commands will run as $(whoami):"
  printf '%s\n' "----------------------------------------" "$steps" "----------------------------------------"
  [ -t 0 ] || {
    echo "refusing to auto-run a modified workflow non-interactively."
    exit 1
  }
  read -rp "Proceed? [y/N] " reply
  [ "$reply" = y ] || [ "$reply" = Y ] || {
    echo "aborted."
    exit 1
  }
fi

bash -euo pipefail <<<"$steps"

echo
echo "✓ local CI passed"
