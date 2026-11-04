/*
  SPDX-License-Identifier: MIT
  Copyright (C) 2026 Jaxxen
*/

# treefmt config — consumed by treefmt-nix (wired in flake.nix). `nix fmt` applies it;
# `nix flake check` enforces it via `checks.formatting`.
#
# Scope is deliberately Nix + shell only. Markdown is excluded (README is contributor-owned
# and CLAUDE.md is hand-tuned to a char budget — auto-reflow would wreck both); the two YAML
# workflows are excluded (curated, with SHA-pin comments not worth a formatter fighting).
{ lib, ... }:
{
  projectRootFile = "flake.nix";

  # Nix: nixfmt — the RFC-style formatter CONTRIBUTING.md mandates.
  programs.nixfmt.enable = true;

  # Shell: shfmt over the standalone .sh files (wrapper + tests). These are plain bash
  # (readFile'd, then @TOKEN@-substituted), not Nix `''…''` here-scripts, so shfmt is safe.
  programs.shfmt.enable = true;

  # treefmt-nix's shfmt module hardcodes `-w -i 2 -s` (a CLI `-i` also makes shfmt ignore
  # .editorconfig). Re-state that list and add `-ci` so `case` arms stay indented, matching
  # the existing scripts. mkForce overrides the module default; if treefmt-nix changes its
  # base flags, mirror them here.
  settings.formatter.shfmt.options = lib.mkForce [
    "-w"
    "-i"
    "2"
    "-s"
    "-ci"
  ];
}
