# ccvm

**CLI for isolating and securing the Claude Code experience with little-to-no added friction**

***100% reproducible from this repository.***

[![check](https://github.com/jx-wi/ccvm/actions/workflows/check.yml/badge.svg)](https://github.com/jx-wi/ccvm/actions/workflows/check.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

**[About](#about) · [Requirements](#requirements) · [Usage](#usage) · [Security](#security) · [Options](#options) · [Installation](#installation) · [Roadmap](#roadmap) · [License](#license)**

---

## About

  `ccvm` aims to be a drop-in replacement for running `claude`

  Running `ccvm` will automatically whip up a RAM-only NixOS microVM and drop you into the same TUI that running `claude` would.

---

## Requirements

  - Linux
  - Nix

---

## Usage

  Installed it already? Run it in any project directory, exactly like `claude`:

  ```bash
  ccvm
  ```

  Just want to try it, without installing anything? With Nix (flakes enabled):

  ```bash
  nix run github:jx-wi/ccvm
  ```

  > [!NOTE]
  > The first run builds the VM image, so it takes a few minutes; after that it's cached and
  > starts quickly.

---

## Security

  By default, ccvm gives you **containment**: Claude runs inside a throwaway VM that can only
  see the one directory you launched it in — not the rest of your machine, your SSH keys, or
  your cloud credentials — and everything it does disappears when you close it.

  Two things worth knowing about the defaults (which are tuned to feel exactly like native
  `claude`):

  - The VM can reach the internet freely, and it reuses your existing Claude login. So a
    misbehaving or prompt-injected agent could, in principle, send your project files or login
    token somewhere it shouldn't.
  - Locking that down is one setting — restrict where the VM is allowed to connect:

    ```nix
    programs.ccvm.egressAllowlist = [ "github.com" "registry.npmjs.org" ];
    # api.anthropic.com is always allowed, so Claude keeps working.
    ```

  For the strictest setup, also stop sharing your Claude config and authenticate with an API
  key instead, so your login token never enters the VM at all:

  ```nix
  programs.ccvm.shareClaudeConfig = false;  # use the ANTHROPIC_API_KEY env var instead
  ```

  The full threat model and design rationale live in [CLAUDE.md](CLAUDE.md).

---

## Options

  > [!NOTE]
  > This section will describe ccvm options based on their home-manager module's names. See [alternate option declarations](#alternate-option-declarations) for configuration via environment variables and/or flags.

  > [!WARNING]
  > Egress is open by default (like native `claude`), so a compromised agent could exfiltrate
  > data — including your OAuth credential when `shareClaudeConfig` is on. Lock it down with
  > `egressAllowlist`, or auth via API key with `shareClaudeConfig = false`. Full threat model: CLAUDE.md.

  Ordered by how often you'll reach for them — essentials first, escape hatches last.

  - `enable`: install the `ccvm` command (default: `false`) (types: `true`/`false`)
  - `writableCwd`: mount the host CWD (the project dir `ccvm` was launched in) read-write so the agent's edits land on the host live; `false` keeps the CWD read-only with edits in an ephemeral overlay discarded on exit. Only this one directory ever crosses to the host (default: `true`) (types: `true`/`false`)
  - `shareClaudeConfig`: read-only mount the host `~/.claude` so the VM reuses your login, settings, commands and memory (default: `true`) (types: `true`/`false`)
  - `memory`: how much RAM in MiB to allocate to the VM (default: `4096`) (types: positive integers)
  - `cores`: how many vCPUs to allocate to the VM (default: `4`) (types: positive integers)
  - `acceleration`: which acceleration type to use (default: `"auto"`) (types: `"auto"`, `"kvm"`, or `"tcg"`)
  - `extraPackages`: additional packages to install into the VM (default: `[]`) (types: list of strings)
  - `nix.enable`: enable Nix in the VM (default: `false`) (types: `true`/`false`)
  - `nix.substituters`: extra binary caches for in-VM Nix (default: `[]`) (types: list of strings)
  - `nix.trustedPublicKeys`: public keys that verify paths from `nix.substituters` (default: `[]`) (types: list of strings)
  - `shareGitConfig`: stage a sanitized copy of your global git config so in-VM `git` commits as you (no credentials/signing keys cross) (default: `true`) (types: `true`/`false`)
  - `persistClaudeProjects`: mount `~/.claude/projects` read-write so transcripts + memory persist back (cross-run `--resume`); scoped to `projects/` so the OAuth credential never crosses (default: `false`) (types: `true`/`false`)
  - `egressAllowlist`: FQDN/IP/CIDR egress allowlist — empty = open egress, non-empty = default-deny firewall (default: `[]`) (types: list of strings)
  - `egressPorts`: destination ports the allowlist permits (default: `[ 443 ]`) (types: list of ports)
  - `agentSudo`: whether the in-VM agent gets passwordless root (sudo); `null` (default) = auto — on for DevEx and `--shell` debugging, but automatically **off** when `egressAllowlist` is set so a compromised agent can't flush the in-guest egress firewall to exfiltrate; `true`/`false` force it (default: `null`) (types: `null`, or `true`/`false`)
  - `vmDiskSize`: GiB of opt-in encrypted ephemeral disk at `/scratch`; `0` keeps pure RAM (default: `0`) (types: non-negative integer)
  - `apiKeyVariable`: host env var carrying the Anthropic API key, passed to the VM only over SSH (default: `"ANTHROPIC_API_KEY"`) (types: string)
  - `extraClaudeMd`: markdown staged as the guest's `~/.claude/CLAUDE.md` telling the agent it's in ccvm (default: built-in blurb) (types: lines; `""` disables)
  - `package`: the claude-code package to run in the VM (default: `pkgs.claude-code`) (types: package)
  - `extraGuestModules`: extra NixOS modules merged into the guest, an escape hatch (default: `[]`) (types: list of modules)
  - `lockGuestMemory`: mlock guest RAM so in-VM secrets can't be paged to host swap. **Takes tinkering to work and isn't recommended for most people** — QEMU refuses to start unless you raise the host's `RLIMIT_MEMLOCK` (`ulimit -l`, systemd `LimitMEMLOCK`, or `limits.conf`). Only worth it if **(a)** your host swap is unencrypted (the one case it actually buys you something) or **(b)** you're willing to do that host setup; otherwise leave it off (default: `false`) (types: `true`/`false`)

### Alternate option declarations

  Per-run env overrides (`CCVM_X == option`):

  - `CCVM_WRITABLE_CWD` == `writableCwd`
  - `CCVM_ACCEL` == `acceleration`
  - `CCVM_MEMORY` == `memory`
  - `CCVM_SHARE_CLAUDE_CONFIG` == `shareClaudeConfig`
  - `CCVM_PERSIST_PROJECTS` == `persistClaudeProjects`
  - `CCVM_SHARE_GIT_CONFIG` == `shareGitConfig`
  - `CCVM_CLAUDE_MD` == `extraClaudeMd`
  - `CCVM_MLOCK` == `lockGuestMemory`
  - `CCVM_VM_DISK_SIZE` == `vmDiskSize`

  ccvm-only flags (consumed, never forwarded to `claude`):

  - `--writable-cwd` / `--read-only-cwd` == `writableCwd` (== `CCVM_WRITABLE_CWD`)
  - `--shell` (debug shell), `--ccvm-debug` (stream console), `--ccvm-help`, `--ccvm-version`

---

## Installation

### home-manager example

  1. Install Nix

  You can find the installer at [nixos.org/download](https://nixos.org/download/).
  You don't need NixOS to use Nix or ccvm. If you aren't on NixOS and don't plan on switching (yet), use the install *script* found at the linked webpage.

  2. Flake configuration

  If you don't already have a repo for your dotfiles, that's fine for now; just make a directory for the flake:

  ```bash
  mkdir -p ~/Projects/yourConfigRepo
  ```

  You'll also need nix-command and flakes enabled. To do this on the user-level, add this to `~/.config/nix/nix.conf`:

  ```
  experimental-features = nix-command flakes
  ```

  In `yourConfigRepo/flake.nix` (ensure you replace all instances of `yourUsername`):

  ```nix
  {
    inputs = {
      nixpkgs.url = "nixpkgs/nixos-unstable";
      ccvm = {
        url = "github:jx-wi/ccvm";
        inputs.nixpkgs.follows = "nixpkgs";
      };
      home-manager = {
        url = "github:nix-community/home-manager";
        inputs.nixpkgs.follows = "nixpkgs";
      };
    };
    outputs = {
      nixpkgs,
      ccvm,
      home-manager,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
      };
    in
    {
      homeConfigurations.yourUsername = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ccvm.homeManagerModules.default
          ./yourUsername/home.nix
        ];
      };
    };
  }
  ```

  Now update the lock file:

  ```bash
  cd ~/Projects/yourConfigRepo && nix flake update ccvm --flake path:.
  ```

  3. home-manager configuration

  Make a folder in the config repo for your home-manager configuration files if you don't already have one:

  ```bash
  mkdir -p ~/Projects/yourConfigRepo/yourUsername
  ```

  In `yourConfigRepo/yourUsername/home.nix` (replace all instances of `yourUsername` again):

  ```nix
  {
    pkgs,
    lib,
    ...
  }:
  {
    home = {
      stateVersion = "26.05";
      username = "yourUsername";
      homeDirectory = "/home/yourUsername";
    };
    programs.ccvm = {
      enable = true;
      acceleration = "kvm";
      cores = 8;
      memory = 8192;
      vmDiskSize = 32;
      nix.enable = true;
      egressAllowlist = [
        "github.com"
        "api.github.com"
        "raw.githubusercontent.com"
        "codeload.github.com"
        "npmjs.com"
        "registry.npmjs.org"
      ];
      extraPackages = with pkgs; [
        bottom
        delta
        eza
        yazi
      ];
    };
    nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
      "claude-code"
    ];
  }
  ```

  Now switch to your new configuration:

  ```bash
  cd ~/Projects/yourConfigRepo && nix run nixpkgs#nh -- home switch path:.
  ```

---

## Roadmap

  - [X] Baseline one-command microVM for Claude Code
  - [X] Network egress controls
  - [X] Encrypted disk support
  - [ ] Authenticated binary cache support
  - [ ] Dedicated CI server for the boot tests

---

## License

  MIT © 2026 Jaxxen. See [LICENSE](LICENSE).
