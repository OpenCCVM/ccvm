# mkCcvm: turn a ccvm configuration into the `ccvm` host wrapper package.
#
# It evaluates the guest NixOS system (guest/default.nix) and extracts the four boot
# artifacts the wrapper needs — kernel, initrd, a read-only squashfs of the system
# closure, and the kernel cmdline — then bakes their store paths (plus the scalar
# config) into wrapper/ccvm.sh. The workspace 9p share and SSH port are NOT baked: they
# are only known at launch time, so the wrapper constructs those QEMU args at runtime
# (this is the microvm.nix runtime-share trap; see CLAUDE.md, "Config flows through @TOKENS@").
#
# Called from both the flake (standalone `nix run`) and the home-manager module, always
# with the caller's own `pkgs`, so guest and host stay on one nixpkgs.
{ pkgs }:
let
  inherit (pkgs) lib;

  # Default config VALUES live in lib/defaults.nix — the single source of truth shared with
  # the home-manager module's option defaults, so the two can't drift. See that file for the
  # per-option semantics; the home-manager module carries the full user-facing descriptions.
  defaults = import ./defaults.nix { inherit pkgs; };
in
userConfig:
let
  # Shallow-merge the top level, then deep-merge the nested attrs (`nix`, `share`) so a caller
  # passing `nix = { enable = true; }` or `share = { plugins = true; }` keeps the other defaults
  # instead of replacing the whole attr.
  # NB: deliberately NOT lib.recursiveUpdate — it recurses into *any* two attrsets, and `package`
  # defaults to a derivation (which IS an attrset), so recursiveUpdate would silently deep-merge two
  # derivations into a broken Frankenstein. A targeted one-level merge of `nix` and `share` (whose
  # children are all scalars) is both safe and exactly what's needed.
  config = (defaults // userConfig) // {
    nix = defaults.nix // (userConfig.nix or { });
    share = defaults.share // (userConfig.share or { });
    clipboard = defaults.clipboard // (userConfig.clipboard or { });
  };

  # agentSudo resolution. null (the default) = AUTO: keep passwordless root in the guest for DevEx,
  # EXCEPT when an egress allowlist is set — then drop the agent's trivial root path so a (prompt-
  # injected) agent cannot `nft flush` the in-guest egress firewall. The firewall is installed by a
  # root systemd oneshot (guest/launcher.nix), NOT the agent, so dropping the agent's sudo leaves
  # enforcement fully intact while removing the bypass. An explicit true/false overrides the auto
  # choice. Guest-build-time only (flips a NixOS option, rebuilds the closure) — no wrapper @TOKEN@,
  # no runtime plumbing. This is the IN-GUEST mitigation; host-side egress enforcement (outside the
  # guest's control entirely) is the complete fix — see CLAUDE.md, "Egress: an allowlist, not Tor".
  agentSudoEnabled =
    if config.agentSudo == null then (config.egressAllowlist == [ ]) else config.agentSudo;
  system = pkgs.stdenv.hostPlatform.system;

  # The wrapper is arch-specific: pick the matching qemu-system binary and a default
  # machine type the arch actually supports. `microvm` is x86-only; aarch64 uses `virt`.
  # On x86_64 these resolve to exactly the previous hardcoded values (qemu-system-x86_64,
  # microvm), so that path is unchanged.
  qemuBin = "qemu-system-${pkgs.stdenv.hostPlatform.qemuArch}";
  defaultMachine = if pkgs.stdenv.hostPlatform.isAarch64 then "virt" else "microvm";

  guestSystem = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    inherit system;
    modules = [
      ../guest/default.nix
      {
        nixpkgs.pkgs = pkgs;
        ccvm = {
          inherit (config) apiKeyVariable extraPackages nix;
          claudePackage = config.package;
          agentSudo = agentSudoEnabled;
          clipboard.images = config.clipboard.images;
        };
      }
    ]
    ++ config.extraGuestModules;
  };

  gc = guestSystem.config;
  toplevel = gc.system.build.toplevel;
  kernel = "${gc.system.build.kernel}/${gc.system.boot.loader.kernelFile}";
  initrd = "${gc.system.build.initialRamdisk}/${gc.system.boot.loader.initrdFile}";

  # The full system closure as a read-only squashfs. Its root holds the store paths by
  # basename, so it mounts directly at /nix/store in the guest. zstd decompresses fast,
  # which matters for boot time.
  storeImage = pkgs.callPackage "${pkgs.path}/nixos/lib/make-squashfs.nix" {
    storeContents = [ toplevel ];
    comp = "zstd -Xcompression-level 6";
    fileName = "ccvm-store";
  };

  # Kernel cmdline for direct boot. init= points into the (now mounted) read-only store.
  append = lib.concatStringsSep " " (gc.boot.kernelParams ++ [ "init=${toplevel}/init" ]);

  # The ccvm-context CLAUDE.md baked to a store file; the wrapper copies it into the seed and
  # the guest lays it at ~/.claude/CLAUDE.md. Empty extraClaudeMd => bake an empty path so the
  # wrapper stages nothing (injection disabled).
  claudeMdFile =
    if config.extraClaudeMd == "" then
      ""
    else
      "${pkgs.writeText "ccvm-context.md" config.extraClaudeMd}";

  # ccvm's own version. Pre-public (no tagged release yet), surfaced by `ccvm --ccvm-version`
  # (baked into the wrapper as @VERSION@). Bump on release.
  version = "0.1.0";

  # Package metadata. Surfaced on the wrapper derivation (so `nix search` / `nix run` see a
  # description and the right binary) and reused by the flake's `apps` outputs to silence the
  # `nix flake check` "lacks attribute 'meta'" warnings. `mainProgram` matches the /bin name.
  meta = {
    description = "Run Claude Code in a throw-away, RAM-only QEMU microVM";
    homepage = "https://github.com/openccvm/ccvm";
    license = lib.licenses.mit;
    mainProgram = "ccvm";
    maintainers = [
      {
        github = "openccvm";
        name = "openccvm";
      }
    ];
    platforms = lib.platforms.linux;
  };

  # nix.substituters / nix.trustedPublicKeys: extra binary caches for in-VM nix (e.g. your own
  # self-hosted cache of pre-built deps). Pure guest-closure config — they flow through the `nix`
  # attr into guest/default.nix's nix.settings, with no wrapper token or runtime plumbing (a binary
  # cache is HTTP substitution, not a mount). Only meaningful with nix.enable; warn (not a hard
  # assert — keeps `nix flake check` evaluable) if set without it, since there is then no in-VM nix.
  wrapper =
    lib.warnIf (config.nix.substituters != [ ] && !config.nix.enable)
      "ccvm: programs.ccvm.nix.substituters has no effect without nix.enable = true (no in-VM nix to use the extra binary caches)."
      (
        pkgs.writeShellApplication {
          name = "ccvm";
          inherit meta;
          runtimeInputs = with pkgs; [
            qemu
            coreutils
            openssh
            findutils
            getent
            git
            jq
            socat
          ];
          text =
            builtins.replaceStrings
              [
                "@KERNEL@"
                "@INITRD@"
                "@STOREIMG@"
                "@APPEND@"
                "@MEMORY@"
                "@CORES@"
                "@MODE@"
                "@APIKEYVAR@"
                "@SHARE_SETTINGS@"
                "@SHARE_CLAUDEMD@"
                "@SHARE_KEYBINDINGS@"
                "@SHARE_COMMANDS@"
                "@SHARE_AGENTS@"
                "@SHARE_SKILLS@"
                "@SHARE_OUTPUTSTYLES@"
                "@SHARE_PLUGINS@"
                "@SHARE_CONFIG@"
                "@PERSISTPROJECTS@"
                "@SHAREGIT@"
                "@CLAUDEMD@"
                "@QEMU@"
                "@DEFAULTMACHINE@"
                "@MEMLOCK@"
                "@EGRESSALLOW@"
                "@EGRESSPORTS@"
                "@VERSION@"
                "@VMDISKSIZE@"
                "@ACCELERATION@"
                "@CLIPIMAGES@"
                "@CLIPGUESTPORT@"
              ]
              [
                kernel
                initrd
                "${storeImage}"
                append
                (toString config.memory)
                (toString config.cores)
                (if config.writableCwd then "rw" else "overlay")
                config.apiKeyVariable
                (if config.share.settings then "1" else "0")
                (if config.share.claudeMd then "1" else "0")
                (if config.share.keybindings then "1" else "0")
                (if config.share.commands then "1" else "0")
                (if config.share.agents then "1" else "0")
                (if config.share.skills then "1" else "0")
                (if config.share.outputStyles then "1" else "0")
                (if config.share.plugins then "1" else "0")
                (if config.share.config then "1" else "0")
                (if config.persistClaudeProjects then "1" else "0")
                (if config.share.gitConfig then "1" else "0")
                claudeMdFile
                qemuBin
                defaultMachine
                (if config.lockGuestMemory then "1" else "0")
                (lib.concatStringsSep " " config.egressAllowlist)
                (lib.concatStringsSep " " (map toString config.egressPorts))
                version
                (toString config.vmDiskSize)
                config.acceleration
                (if config.clipboard.images then "1" else "0")
                (toString gc.ccvm.clipboard.port)
              ]
              (builtins.readFile ../wrapper/ccvm.sh);
        }
      );
in
# Audit S-2: a few config values are baked into the wrapper as raw shell (APIKEYVAR="@APIKEYVAR@",
# EGRESSALLOW="@EGRESSALLOW@", …). The module types keep them strings but not shell-safe, so validate
# at eval time — a stray quote / `$(…)` would otherwise become code in the generated wrapper. Only
# the user's own (trusted) config feeds this, so these are footgun guards, not a trust boundary.
assert lib.assertMsg (builtins.match "[A-Za-z_][A-Za-z0-9_]*" config.apiKeyVariable != null)
  "ccvm: apiKeyVariable must be a valid shell/env identifier ([A-Za-z_][A-Za-z0-9_]*); got '${config.apiKeyVariable}'.";
assert lib.assertMsg
  (lib.all (e: builtins.match "[A-Za-z0-9._:/-]+" e != null) config.egressAllowlist)
  "ccvm: every egressAllowlist entry must be an FQDN / IP / CIDR ([A-Za-z0-9._:/-]); got [ ${lib.concatStringsSep " " config.egressAllowlist} ].";
{
  inherit
    wrapper
    guestSystem
    toplevel
    storeImage
    append
    kernel
    initrd
    config
    meta
    ;
  kernelParams = gc.boot.kernelParams;
}
