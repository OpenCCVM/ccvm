/*
  SPDX-License-Identifier: MIT
  Copyright (C) 2026 Jaxxen
*/

# Single source of truth for ccvm's default configuration VALUES.
#
# Imported by BOTH lib/mkccvm.nix (the merge baseline for an explicit `mkCcvm { … }` call)
# and modules/home-manager.nix (each programs.ccvm.* option's `default`), so the two can
# never drift. Keep the user-facing option DESCRIPTIONS in the home-manager module; keep the
# VALUES (and only a one-line reminder of what each is) here.
{ pkgs }:
{
  package = pkgs.claude-code; # the claude-code package to run inside the VM (unfree)
  writableCwd = true; # true = host CWD writable, edits land live (rw, native); false = read-only, ephemeral overlay
  memory = 4096; # guest RAM in MiB (runtime QEMU arg; CCVM_MEMORY overrides per run)
  cores = 4; # guest vCPUs
  acceleration = "auto"; # VM CPU accel: "auto" (KVM w/ TCG fallback) | "kvm" (require KVM, error if unusable) | "tcg" (force emulation). Per-run: CCVM_ACCEL
  extraPackages = [ ]; # extra toolchains available inside the VM (a base set is always present)
  nix = {
    enable = false; # build-time: enable in-VM nix (writable /nix/store overlay + nix.enable). User-facing: programs.ccvm.nix.enable
    substituters = [ ]; # extra binary caches for in-VM nix (HTTP substituters; needs nix.enable). Empty = just cache.nixos.org
    trustedPublicKeys = [ ]; # public keys that verify paths from `substituters`
  };
  apiKeyVariable = "ANTHROPIC_API_KEY"; # host env var carrying the key (rides SendEnv only)
  # Granular allowlist for what crosses from the host ~/.claude into the VM.
  # Everything else (projects/, sessions/, history.jsonl, .credentials.json, etc.) NEVER crosses.
  share = {
    gitConfig = true; # stage a sanitized global git config (was: shareGitConfig)
    settings = true; # ~/.claude/settings.json + settings.local.json
    claudeMd = true; # ~/.claude/CLAUDE.md (global memory)
    keybindings = true; # ~/.claude/keybindings.json (custom keyboard shortcuts)
    commands = true; # ~/.claude/commands/
    agents = true; # ~/.claude/agents/
    skills = true; # ~/.claude/skills/
    outputStyles = true; # ~/.claude/output-styles/ (custom output styles)
    plugins = false; # ~/.claude/plugins/
    config = false; # ~/.claude/config/
  };
  persistClaudeProjects = false; # persist ~/.claude/projects back to the host (resume + memory)
  clipboard = {
    images = true; # bridge host clipboard IMAGES into the VM so Ctrl+V image paste works (image-only, never host text). Per-run: CCVM_CLIPBOARD_IMAGES
  };
  # guest ~/.claude/CLAUDE.md ("you're in ccvm"), without the source file's SPDX header
  extraClaudeMd =
    let
      inherit (pkgs) lib;
      raw = builtins.readFile ./ccvm-context.md;
      sep = "  -->\n\n";
    in
    if lib.hasPrefix "<!-- SPDX-License-Identifier:" raw then
      lib.concatStringsSep sep (lib.tail (lib.splitString sep raw))
    else
      raw;
  agentSudo = null; # null=auto: passwordless root in the guest, but DROPPED when egressAllowlist is set (so the agent can't `nft flush` the in-guest egress firewall). true/false forces it. Resolved in mkccvm.nix
  lockGuestMemory = false; # mlock guest RAM so it can't reach host swap
  vmDiskSize = 0; # GiB; 0=off. >0 attaches an encrypted ephemeral disk pool (/scratch; later writable store)
  egressAllowlist = [ ]; # opt-in egress allowlist; empty = open egress (native default)
  egressPorts = [ 443 ]; # dst ports the allowlist permits (only when egressAllowlist is set)
  extraGuestModules = [ ]; # extra NixOS modules merged into the guest (escape hatch)
}
