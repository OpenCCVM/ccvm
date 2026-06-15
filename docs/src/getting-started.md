# Getting started

## Requirements

- **Linux**
- **Nix** (with flakes enabled)

No NixOS required — Nix on any Linux distribution works. If you don't have Nix yet, install it with
the [official installer](https://nixos.org/download/), then enable flakes once by adding this to
`~/.config/nix/nix.conf`:

```
experimental-features = nix-command flakes
```

KVM is used automatically when available and falls back to software emulation (TCG) otherwise, so
ccvm runs even where `/dev/kvm` is unavailable — just more slowly. See
[`acceleration`](options.md#acceleration) to force a mode.

## Try it without installing

With Nix and flakes enabled, run ccvm straight from the repository in any project directory:

```bash
nix run github:openccvm/ccvm
```

> The first run builds the VM image, so it takes a few minutes; after that it's cached and starts
> quickly.

## Run it once installed

Once installed (see below), run it in any project directory, exactly like `claude`:

```bash
ccvm
```

Everything after `ccvm` is forwarded to `claude` verbatim — including
`--dangerously-skip-permissions`, which is safe to opt into precisely because the VM is the trust
boundary.

## First run: authenticating

ccvm brings your `~/.claude` **settings** into the VM but **not your login** — the OAuth credential
is excluded by construction (see [Security invariants](security/invariants.md)). So on first run,
authenticate one of two ways:

- **`/login` inside the VM** — the resulting token lives in the VM's ephemeral tmpfs and is wiped
  on exit. It never touches your host's stored credential.
- **`ANTHROPIC_API_KEY`** — set it in your host environment before launching. ccvm passes it to the
  VM **only over the SSH channel** (never on disk, argv, or the kernel command line). The host
  variable name is configurable via [`apiKeyVariable`](options.md#apikeyvariable).

## Installing with home-manager

ccvm ships a home-manager module that exposes `programs.ccvm.*` and installs the `ccvm` command.

### 1. Install Nix

Use the [official installer](https://nixos.org/download/). You don't need NixOS to use Nix or ccvm.
If you're not on NixOS and don't plan to switch, use the install *script* on that page.

### 2. Flake configuration

If you don't already have a dotfiles repo, make a directory for the flake:

```bash
mkdir -p ~/Projects/yourConfigRepo
```

Enable `nix-command` and flakes (per-user) by adding to `~/.config/nix/nix.conf`:

```
experimental-features = nix-command flakes
```

In `yourConfigRepo/flake.nix` (replace every `yourUsername`):

```nix
{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-26.05";
    ccvm = {
      url = "github:openccvm/ccvm";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    {
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
          ccvm.homeModules.ccvm
          ./yourUsername/home.nix
        ];
      };
    };
}
```

Update the lock file:

```bash
cd ~/Projects/yourConfigRepo && nix flake update ccvm --flake path:.
```

### 3. home-manager configuration

Make a folder for your home-manager files if you don't have one:

```bash
mkdir -p ~/Projects/yourConfigRepo/yourUsername
```

In `yourConfigRepo/yourUsername/home.nix` (replace every `yourUsername` again):

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
    cores = 8;
    memory = 8192;
    vmDiskSize = 32;
    nix.enable = true;
    egressAllowlist = [
      "cache.nixos.org"
      "storage.googleapis.com"
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
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "claude-code"
    ];
}
```

> **`claude-code` is unfree**, so a consuming config must allow it. The
> `allowUnfreePredicate` above is the form that works in a real home-manager activation —
> the name that matches is **`claude-code`** (the bare name `claude` is rejected; don't
> simplify it). `nix run github:openccvm/ccvm` needs none of this — ccvm's own build allows unfree
> internally.

Switch to your new configuration:

```bash
cd ~/Projects/yourConfigRepo && nix run nixpkgs#nh -- home switch path:.
```

See the [Options](options.md) reference for everything `programs.ccvm.*` can set.

## The Ctrl+Z caveat

**Avoid pressing Ctrl+Z inside ccvm.** Claude Code treats Ctrl+Z as suspend and stops itself, but
the VM has no job-control shell to bring it back — so the session freezes. If it happens, disconnect
and start again (the VM is ephemeral, so nothing is lost beyond the session). This is **upstream
Claude Code behavior**, not specific to ccvm, and there is no guest-side fix — the signal involved
is uncatchable. See [Gotchas → Ctrl+Z](developing/gotchas.md#ctrlz-freezes-the-session) for the
gory technical detail.
