/*
  SPDX-License-Identifier: MIT
  Copyright (C) 2026 Jaxxen
*/

# home-manager module: programs.ccvm.* -> installs the `ccvm` command.
#
# Each option feeds lib/mkccvm.nix, which builds a self-contained guest image and bakes
# it into the wrapper. Changing memory/cores is cheap (runtime QEMU args); changing
# package/extraPackages/nix.enable rebuilds the guest closure.
#
# Exposed from the flake as `import ./modules/home-manager.nix { inherit claude-code; }`, so it
# closes over the community nix-claude-code flake — a consumer's nixpkgs has no view of our
# inputs, so we apply claude-code's overlay to *their* pkgs to land the same `pkgs.claude-code`.
{ claude-code }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ccvm;
  # The consumer's pkgs with the community claude-code overlay applied, so `package` (and the
  # guest's `pkgs.claude-code`) resolve to the same build the standalone flake uses.
  pkgs' = pkgs.extend claude-code.overlays.default;
  mkCcvm = import ../lib/mkccvm.nix { pkgs = pkgs'; };
  # Option defaults come from the SAME source mkccvm.nix uses, so a default can't drift
  # between the two. Only the user-facing descriptions live here.
  defaults = import ../lib/defaults.nix { pkgs = pkgs'; };
  ccvmPkg =
    (mkCcvm {
      inherit (cfg)
        package
        writableCwd
        memory
        cores
        acceleration
        extraPackages
        apiKeyVariable
        share
        persistClaudeProjects
        clipboard
        extraClaudeMd
        agentSudo
        lockGuestMemory
        vmDiskSize
        egressAllowlist
        egressPorts
        extraGuestModules
        # programs.ccvm.nix.{enable,substituters,trustedPublicKeys} passes straight through — the
        # internal config and the guest use the SAME nested `nix` name (no nixInVm mapping anymore).
        nix
        ;
    }).wrapper;
in
{
  imports = [
    # shareGitConfig was a top-level option; it is now programs.ccvm.share.gitConfig.
    # This rename keeps existing configs working with a deprecation warning.
    (lib.mkRenamedOptionModule
      [ "programs" "ccvm" "shareGitConfig" ]
      [ "programs" "ccvm" "share" "gitConfig" ]
    )
  ];

  options.programs.ccvm = {
    enable = lib.mkEnableOption "ccvm — ephemeral microVM wrapper for Claude Code";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaults.package;
      defaultText = lib.literalExpression "pkgs.claude-code";
      description = "The claude-code package to run inside the VM (unfree; override/pin as you like).";
    };

    writableCwd = lib.mkOption {
      type = lib.types.bool;
      default = defaults.writableCwd;
      description = ''
        true (default): the host CWD (the project dir `ccvm` was launched in) is mounted
        read-write; the agent's edits land on the host live — identical to native `claude`.
        false (secure): the host CWD is read-only; the agent still sees and edits a full
        tree, but writes go to an ephemeral overlay and vanish on exit (export via `git
        push`). Only this one directory ever crosses to the host. Per-run override:
        `ccvm --read-only-cwd` / `--writable-cwd`, or `CCVM_WRITABLE_CWD=0|1`.
      '';
    };

    memory = lib.mkOption {
      type = lib.types.ints.positive;
      default = defaults.memory;
      description = ''
        VM RAM in MiB. Per-run override without a rebuild: `CCVM_MEMORY=<MiB> ccvm …`
        (memory is a runtime QEMU arg) — handy for a heavy `nix develop` / build closure.
      '';
    };

    cores = lib.mkOption {
      type = lib.types.ints.positive;
      default = defaults.cores;
      description = "VM vCPUs.";
    };

    acceleration = lib.mkOption {
      type = lib.types.enum [
        "auto"
        "kvm"
        "tcg"
      ];
      default = defaults.acceleration;
      description = ''
        VM CPU acceleration mode.
        - `auto` (default): use KVM when `/dev/kvm` is usable, otherwise fall back to software
          emulation (TCG). Never errors on acceleration — the friction-free first-run experience.
        - `kvm`: require KVM. Fails fast with an actionable reason if it can't be used (no
          `/dev/kvm`, not in the `kvm` group, not writable) and does NOT silently fall back, so a
          misconfigured host is obvious instead of silently slow.
        - `tcg`: force software emulation. Slower, but works anywhere KVM doesn't — nested virt, CI,
          or a present-but-broken `/dev/kvm`.
        Per-run override: `CCVM_ACCEL=auto|kvm|tcg`.
      '';
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = defaults.extraPackages;
      example = lib.literalExpression "with pkgs; [ go gopls nodejs python3 ]";
      description = "Extra packages available inside the VM (project toolchains). A sensible base set is always included.";
    };

    nix = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = defaults.nix.enable;
        description = ''
          Enable a usable `nix` inside the VM (in-VM `nix develop`/`nix build`). Off by default —
          the default guest is RAM-only with a read-only /nix/store. When on, the guest is built with
          `nix.enable` and a WRITABLE /nix/store overlay (the read-only store image as the lower, a
          writable upper); nix realises new paths into the upper. Build-time (rebuilds the guest), not
          a runtime env var, because a writable store must be set up in the initrd. The upper is
          tmpfs (RAM) by default — a large `nix develop` will exhaust guest RAM until you also set
          `vmDiskSize`, which relocates the upper onto the encrypted ephemeral disk. Everything stays
          wipe-on-exit. Security note: enabling nix makes the agent a Nix client of the root daemon.
          To keep that from becoming a root path, the agent is a Nix `trusted-user` ONLY while it also
          has sudo; setting `egressAllowlist` (or `agentSudo = false`) drops both together, so a
          non-trusted agent can still build but can't override trusted-only settings to regain root
          and flush the egress firewall (see `agentSudo`).
        '';
      };

      substituters = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = defaults.nix.substituters;
        example = lib.literalExpression ''[ "https://cache.example.com" ]'';
        description = ''
          Extra binary caches (nix substituters) for in-VM nix to pull pre-built paths from, instead
          of rebuilding them. Only meaningful with `nix.enable = true`. Each entry is a substituter
          URL — typically your own self-hosted cache of tweaked/private deps (attic, nix-serve, an S3
          bucket, …). These are appended to the default `cache.nixos.org` (set a per-URL
          `?priority=N` if you want to reorder), and pulled over HTTP at network speed — no mount, no
          host-store exposure. Paths must verify against `trustedPublicKeys`, so signatures stay on
          (require-sigs is NOT disabled). A PUBLIC-READ signed cache works with zero secrets; a cache
          behind a token/netrc is not yet supported (ccvm carries no host credentials — a sanitized
          netrc-staging path, like shareGitConfig, would be needed). Build-time (the URLs are baked
          into the guest's nix.conf); no per-run env override.
        '';
      };

      trustedPublicKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = defaults.nix.trustedPublicKeys;
        example = lib.literalExpression ''[ "cache.example.com:abc123…=" ]'';
        description = ''
          Public keys that verify paths fetched from `nix.substituters` (the `name:base64key` pairs
          a self-hosted cache prints on setup). Appended to nixpkgs' built-in trusted keys. Without
          the matching key, nix refuses a substituter's paths as untrusted — so set this alongside
          `substituters`. Only meaningful with `nix.enable = true`.
        '';
      };
    };

    apiKeyVariable = lib.mkOption {
      type = lib.types.str;
      default = defaults.apiKeyVariable;
      description = "Name of the host env var carrying the Anthropic API key. Passed to the VM only over the encrypted SSH channel (SendEnv); never written to disk or argv.";
    };

    # Granular allowlist controlling which parts of ~/.claude cross into the VM.
    # Replaces the old all-or-nothing shareClaudeConfig. Everything NOT listed here
    # (projects/, sessions/, history.jsonl, .credentials.json, …) NEVER crosses.
    share = {
      gitConfig = lib.mkOption {
        type = lib.types.bool;
        default = defaults.share.gitConfig;
        description = ''
          true (default): stage a SANITIZED copy of your global git config into the VM (laid at
          ~/.config/git/config) so in-VM `git` commits as you, with your aliases and global
          ignores — like native `claude`. "Sanitized" means host-only settings that would dangle
          or leak are dropped: any value pointing into /nix/store (home-manager's editor / pager /
          delta / gh credential-helper paths), all credential.* helpers (no host credentials cross
          the boundary — ~/.ssh and gh tokens are never shared), and signing is force-disabled
          (the signing key is deliberately not carried, so a leftover commit.gpgsign would only
          break commits). The global core.excludesfile is staged by content to the VM's default
          ignore path. Commits work as you; pushing to an SSH remote still needs credentials the
          VM does not have (by design). false: stage nothing. Per-run: CCVM_SHARE_GIT_CONFIG=0|1.
          (Renamed from programs.ccvm.shareGitConfig — existing configs are migrated automatically.)
        '';
      };

      settings = lib.mkOption {
        type = lib.types.bool;
        default = defaults.share.settings;
        description = ''
          true (default): copy the host's ~/.claude/settings.json and ~/.claude/settings.local.json
          into the VM so it starts with your theme, model, and other preferences. home-manager
          symlinks are dereferenced. The copy is staged into the seed (a tmpfs ~/.claude in the
          guest), so any in-VM writes stay ephemeral — they never reach the host. Also gates
          ~/.claude.json staging (the home-root startup config): its known secret-bearing keys
          (mcpServers[].env, mcpServers[].headers, primaryApiKey) are stripped before staging.
          false: share no settings. Per-run: CCVM_SHARE_SETTINGS=0|1.
        '';
      };

      claudeMd = lib.mkOption {
        type = lib.types.bool;
        default = defaults.share.claudeMd;
        description = ''
          true (default): copy the host's ~/.claude/CLAUDE.md (your global memory / instruction
          file) into the VM. The ccvm-context blurb (extraClaudeMd) is APPENDED to it so the
          agent knows it is inside a ccvm VM — the host file is never modified. false: the guest
          sees only the ccvm-context blurb. Per-run: CCVM_SHARE_CLAUDEMD=0|1.
        '';
      };

      keybindings = lib.mkOption {
        type = lib.types.bool;
        default = defaults.share.keybindings;
        description = ''
          true (default): copy the host's ~/.claude/keybindings.json (your custom keyboard
          shortcuts) into the VM, dereferencing home-manager symlinks, so the in-VM TUI uses
          your bindings. Staged into the tmpfs ~/.claude, so in-VM writes stay ephemeral. It
          carries no secrets (just keystroke→action maps). false: the guest uses Claude Code's
          default bindings. Per-run: CCVM_SHARE_KEYBINDINGS=0|1.
        '';
      };

      commands = lib.mkOption {
        type = lib.types.bool;
        default = defaults.share.commands;
        description = ''
          true (default): copy the host's ~/.claude/commands/ directory into the VM so your
          custom slash commands are available. false: no custom commands. Per-run: CCVM_SHARE_COMMANDS=0|1.
        '';
      };

      agents = lib.mkOption {
        type = lib.types.bool;
        default = defaults.share.agents;
        description = ''
          true (default): copy the host's ~/.claude/agents/ directory into the VM so your
          custom sub-agents are available. false: no custom agents. Per-run: CCVM_SHARE_AGENTS=0|1.
        '';
      };

      skills = lib.mkOption {
        type = lib.types.bool;
        default = defaults.share.skills;
        description = ''
          true (default): copy the host's ~/.claude/skills/ directory into the VM so your
          custom skills are available. false: no custom skills. Per-run: CCVM_SHARE_SKILLS=0|1.
        '';
      };

      outputStyles = lib.mkOption {
        type = lib.types.bool;
        default = defaults.share.outputStyles;
        description = ''
          true (default): copy the host's ~/.claude/output-styles/ directory into the VM so your
          custom output styles are available. The ACTIVE style selection already crosses via
          share.settings; this brings the style DEFINITIONS it points at. false: no custom output
          styles (a selected one falls back to a built-in). Per-run: CCVM_SHARE_OUTPUTSTYLES=0|1.
        '';
      };

      plugins = lib.mkOption {
        type = lib.types.bool;
        default = defaults.share.plugins;
        description = ''
          false (default): do NOT copy the host's ~/.claude/plugins/ into the VM. Plugins can
          carry executable code and network credentials, so they are off by default. Set true to
          share them; they still run in the ephemeral guest and cannot reach the host filesystem.
          Per-run: CCVM_SHARE_PLUGINS=0|1.
        '';
      };

      config = lib.mkOption {
        type = lib.types.bool;
        default = defaults.share.config;
        description = ''
          false (default): do NOT copy the host's ~/.claude/config/ directory into the VM. Set
          true to share it. Per-run: CCVM_SHARE_CONFIG=0|1.
        '';
      };
    };

    # Deprecated: use programs.ccvm.share.{settings,claudeMd,commands,agents,skills} instead.
    # Setting this emits a warning; the value is otherwise ignored (individual share.* options
    # control what crosses). Runtime env var back-compat: CCVM_SHARE_CLAUDE_CONFIG=0/1 still
    # works in the wrapper and toggles all claude items together.
    shareClaudeConfig = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      visible = false;
      description = ''
        DEPRECATED. Use programs.ccvm.share.{settings,claudeMd,commands,agents,skills} instead.
        The old all-or-nothing shareClaudeConfig has been replaced by a per-item allowlist; set
        individual share.* options. The runtime env var CCVM_SHARE_CLAUDE_CONFIG=0|1 still works
        as a back-compat toggle for all claude items.
      '';
    };

    persistClaudeProjects = lib.mkOption {
      type = lib.types.bool;
      default = defaults.persistClaudeProjects;
      description = ''
        false (default): Claude's writes to ~/.claude/projects inside the VM — per-project
        SESSION TRANSCRIPTS and MEMORY — land in the ephemeral tmpfs ~/.claude and vanish on
        exit, so a session started in ccvm cannot be `claude --resume`d in a later run ("ID not
        found") and memories do not survive. true: mount the host's ~/.claude/projects into the
        VM read-WRITE so those writes persist back to the host, making cross-run resume and
        memory work like native `claude`. Deliberately scoped to projects/ ONLY — the OAuth
        credential (~/.claude/.credentials.json, at the ~/.claude ROOT, not under projects/) is
        never staged and never in this share, so it is still never written back to the host.
        Per-run override: CCVM_PERSIST_PROJECTS=0|1.
      '';
    };

    clipboard.images = lib.mkOption {
      type = lib.types.bool;
      default = defaults.clipboard.images;
      description = ''
        true (default): make Claude Code's Ctrl+V IMAGE paste work inside the VM, like native
        `claude`. Claude reads clipboard images by shelling out to `xclip`/`wl-paste`; the guest has
        no X/Wayland and no view of the host clipboard, so without this paste silently no-ops. ccvm
        bridges it by reverse-forwarding a single guest-loopback port back over the EXISTING SSH
        channel to a tiny host clipboard server (a `socat` listener the wrapper starts); fake
        in-guest `xclip`/`wl-paste` shims fetch the host clipboard IMAGE through it. Security: the
        bridge rides loopback + the established SSH connection, so it opens NO hole in the egress
        firewall and works under hardened egress too; sshd permits only this one reverse forward
        (AllowTcpForwarding=remote + PermitListen). It is IMAGE-ONLY by construction — the host
        server never reads clipboard TEXT and the shims never WRITE the host clipboard — so host
        clipboard text (passwords/tokens) can never cross; this is strictly LESS clipboard exposure
        than native `claude`, where the agent can read clipboard text and images at will. The one
        honest residual under OPEN egress: a prompt-injected agent can pull whatever IMAGE is on the
        host clipboard at any time and exfiltrate it (same class as the project tree). It is inert
        unless a host clipboard tool (`wl-paste`/`xclip`) is present; if none is found the bridge
        simply stays off. Build-time (installs the shims + sshd rule); the per-run env var can only
        DISABLE it (CCVM_CLIPBOARD_IMAGES=0) — re-enabling needs the built-in default. false: no
        shims, sshd forwarding stays fully off. See CLAUDE.md, "Image paste".
      '';
    };

    extraClaudeMd = lib.mkOption {
      type = lib.types.lines;
      default = defaults.extraClaudeMd;
      defaultText = lib.literalMD "the contents of `lib/ccvm-context.md`, without its SPDX header";
      description = ''
        Markdown staged as the guest's ~/.claude/CLAUDE.md (global memory) so the agent knows
        it is running inside ccvm — ephemeral, sandboxed, only the project directory shared —
        and adapts (it can be more autonomous; commits work but `git push` to an SSH remote
        does not). It is staged through the read-only seed and laid into the tmpfs ~/.claude,
        NOT passed as a claude flag, so ccvm's transparent-passthrough invariant holds. When
        share.claudeMd brings a host ~/.claude/CLAUDE.md, this is APPENDED to it (the host
        file is never modified). The wrapper also prepends a runtime-accurate note about the
        current file-sharing mode (rw = edits are live on the host; overlay = edits are
        discarded on exit). Defaults to a sensible built-in blurb; set to "" to inject nothing,
        or replace it with your own. Per-run override: CCVM_CLAUDE_MD=<file> (empty disables).
      '';
    };

    vmDiskSize = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = defaults.vmDiskSize;
      example = 32;
      description = ''
        Opt-in encrypted ephemeral disk, in GiB. 0 (default) keeps the pure-RAM model; a positive
        size (e.g. 32) attaches a raw SPARSE virtio-blk image — created in a disk-backed dir on the
        host, NOT tmpfs — which the guest LUKS-encrypts with a key it generates in its OWN RAM (the
        key never crosses 9p; the host only ever sees ciphertext). It is the VM's writable disk
        POOL for bulk, non-secret data that would otherwise exhaust the RAM-backed tmpfs: currently
        a /scratch mount (build outputs, node_modules/target/.venv, caches), and — once the
        writable-store increment lands — an overlay upper for a writable /nix/store (in-VM `nix
        develop`/`nix build`). HOME and root stay tmpfs, so secrets (/login creds, API key, agent
        memory) never leave guest RAM. Wiped on exit: the key dies with guest RAM (leaving inert
        ciphertext) and the host image is removed. The host image dir is
        ''${XDG_CACHE_HOME:-~/.cache}/ccvm by default (override CCVM_SCRATCH_DIR); a tmpfs target is
        refused unless CCVM_SCRATCH_ALLOW_TMPFS=1. Sparse, so it only consumes what's written up to
        the cap. Per-run override: CCVM_VM_DISK_SIZE=<GiB>|0.
      '';
    };

    agentSudo = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = defaults.agentSudo;
      example = false;
      description = ''
        Whether the in-VM agent (the `ccvm` user) has passwordless root (wheel + sudo).
        - `null` (default): AUTO — passwordless root is ON for DevEx and `--shell` debugging, but
          turns OFF automatically whenever `egressAllowlist` is set. This is load-bearing: the egress
          firewall runs *inside* the guest, so a root agent could otherwise simply `nft flush` it and
          exfiltrate freely. Dropping the agent's root closes that bypass while leaving the firewall
          (installed by a root systemd unit, not the agent) fully in force.
        - `true`: force passwordless root on even with an allowlist — you accept that the in-guest
          firewall is then agent-bypassable (only sensible behind host-side egress control).
        - `false`: force it off — the agent cannot sudo; the in-guest firewall holds.
        Whenever the agent's sudo is off (auto under an allowlist, or forced `false`) it is ALSO
        removed from Nix `trusted-users` — otherwise, with `nix.enable`, a trusted-user (which is
        root-equivalent: it can run a `post-build-hook` as root) could regain root through the daemon
        and flush the firewall, undoing the drop. So the two move together.
        Build-time (rebuilds the guest closure). This is the IN-GUEST mitigation; a determined agent
        could still attempt a guest-kernel exploit, so the complete fix for hostile egress is
        host-side enforcement outside the guest entirely.
      '';
    };

    lockGuestMemory = lib.mkOption {
      type = lib.types.bool;
      default = defaults.lockGuestMemory;
      description = ''
        Lock the VM's guest RAM into host memory (QEMU -overcommit mem-lock=on) so it can
        never be paged out to the host's (possibly unencrypted) swap — keeping in-VM secrets
        (the API key in the guest environment, /login credentials in tmpfs) off host disk.
        Off by default; requires a large enough RLIMIT_MEMLOCK or QEMU will not start.
        Per-run override: CCVM_MLOCK=0|1.
      '';
    };

    egressAllowlist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = defaults.egressAllowlist;
      example = lib.literalExpression ''[ "github.com" "registry.npmjs.org" "10.0.0.0/8" ]'';
      description = ''
        Opt-in network egress allowlist. Empty (default) keeps egress fully OPEN, so the
        agent reaches anything like native `claude` (the deliberate native-mirroring default).
        A non-empty list switches the guest to a DEFAULT-DENY egress firewall that permits only
        these destinations on `egressPorts`, plus DNS — closing the prompt-injection
        exfiltration channel. Entries may be FQDNs, bare IPs, or CIDRs. `api.anthropic.com` is
        always auto-included so auth never breaks. FQDNs are resolved on the host at launch and
        pinned BOTH in the firewall and in the guest's /etc/hosts, so the in-VM resolver returns
        exactly those IPs — round-robin / CDN hosts like `github.com` work for the session. The pin
        is session-static, so a host that rotates ALL its IPs away mid-session can drop out;
        restart, or use a CIDR for hosts that churn hard (e.g. GitHub's ranges at
        api.github.com/meta). See CLAUDE.md, "Egress".
      '';
    };

    egressPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = defaults.egressPorts;
      description = "Destination ports the egress allowlist permits (only used when egressAllowlist is non-empty). Add 80 for plain-HTTP mirrors/redirects.";
    };

    extraGuestModules = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = defaults.extraGuestModules;
      description = "Extra NixOS modules merged into the guest configuration (escape hatch).";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ ccvmPkg ];
    warnings =
      lib.optional (cfg.shareClaudeConfig != null)
        "programs.ccvm.shareClaudeConfig is deprecated — use programs.ccvm.share.{settings,claudeMd,commands,agents,skills} instead. The per-item share.* options default to the same sensible values. The runtime env var CCVM_SHARE_CLAUDE_CONFIG=0|1 still works as a back-compat toggle for all claude items.";
  };
}
