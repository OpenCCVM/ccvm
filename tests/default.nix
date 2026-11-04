/*
  SPDX-License-Identifier: MIT
  Copyright (C) 2026 Jaxxen
*/

# Automated checks for ccvm. Returns an attrset of derivations consumed by the flake's
# `checks` output (so `nix flake check` runs them).
#
# The host-side guarantees (secret hygiene, config staging, verbatim argv, mode selection)
# are tested against the *real* wrapper script driven by its CCVM_DRYRUN hook. We bake it
# with DUMMY boot artifacts here — the dry run stops before QEMU, so kernel/initrd/store
# are never touched — which means this check needs neither a guest build nor claude-code
# and runs in seconds. See tests/host.sh for the assertions and tests/boot.sh for the
# full-boot smoke test that genuinely needs a VM (run manually / locally under TCG).
{ pkgs }:
let
  # The same wrapper template the real build uses, with stand-in boot tokens (the dry-run
  # hook exits before QEMU, so kernel/initrd/store are never read). `egressAllow`/`egressPorts`
  # let a check pick the baked egress posture; everything else stays at the production
  # defaults (share-claude-config on, rw mode, open egress).
  mkDryRunWrapper =
    {
      egressAllow ? "",
      egressPorts ? "443",
    }:
    pkgs.writeShellApplication {
      name = "ccvm";
      runtimeInputs = with pkgs; [
        coreutils
        openssh
        findutils
        getent
        git
        jq
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
            "/dev/null" # KERNEL    } never read: the dry-run hook exits before boot.
            "/dev/null" # INITRD    }
            "/dev/null" # STOREIMG  }
            "console=ttyS0" # APPEND
            "4096" # MEMORY
            "4" # CORES
            "rw" # MODE             (production default: writableCwd=true)
            "ANTHROPIC_API_KEY" # APIKEYVAR
            "1" # SHARE_SETTINGS    (production default: share.settings=true)
            "1" # SHARE_CLAUDEMD    (production default: share.claudeMd=true)
            "1" # SHARE_KEYBINDINGS (production default: share.keybindings=true)
            "1" # SHARE_COMMANDS    (production default: share.commands=true)
            "1" # SHARE_AGENTS      (production default: share.agents=true)
            "1" # SHARE_SKILLS      (production default: share.skills=true)
            "1" # SHARE_OUTPUTSTYLES (production default: share.outputStyles=true)
            "0" # SHARE_PLUGINS     (production default: share.plugins=false)
            "0" # SHARE_CONFIG      (production default: share.config=false)
            "0" # PERSISTPROJECTS   (production default: persistClaudeProjects=false)
            "1" # SHAREGIT          (production default: share.gitConfig=true)
            # CLAUDEMD: a fixture context file so the staging block has something to read; host.sh
            # asserts its marker + the runtime mode line reach seed/claude-md (production bakes the
            # real lib/ccvm-context.md).
            "${pkgs.writeText "ccvm-test-context.md" "CCVM-CONTEXT-MARKER baked blurb body\n"}"
            "true" # QEMU        (never invoked under dry run)
            "microvm" # DEFAULTMACHINE
            "0" # MEMLOCK
            egressAllow # EGRESSALLOW (empty = open egress, the default)
            egressPorts # EGRESSPORTS
            "0.0.0-test" # VERSION (fixture; host.sh asserts --ccvm-version echoes it)
            "0" # VMDISKSIZE (0 = no disk, the default; host.sh opts in via CCVM_VM_DISK_SIZE)
            "auto" # ACCELERATION (default mode; host.sh drives modes via CCVM_ACCEL + CCVM_KVM_DEV)
            "1" # CLIPIMAGES (production default: clipboard.images=true)
            "9180" # CLIPGUESTPORT (guest-loopback port for the image-paste shims)
          ]
          (builtins.readFile ../wrapper/ccvm.sh);
    };

  dryRunWrapper = mkDryRunWrapper { };
  egressWrapper = mkDryRunWrapper {
    egressAllow = "10.0.0.0/8";
    egressPorts = "80 443";
  };
  # FQDN-only allowlist (no literal IPs): offline it resolves to nothing, so the wrapper must
  # fail closed (die) rather than boot with an unenforceable allowlist. `.invalid` (RFC 6761)
  # never resolves, so even with network only api.anthropic.com could populate the set — the
  # test self-gates on DNS availability.
  egressFqdnWrapper = mkDryRunWrapper { egressAllow = "nothing.invalid"; };
in
{
  host =
    pkgs.runCommand "ccvm-host-tests"
      {
        nativeBuildInputs = [
          pkgs.bash
          dryRunWrapper
        ];
      }
      ''
        export CCVM=${dryRunWrapper}/bin/ccvm
        bash ${./host.sh}
        touch "$out"
      '';

  egress =
    pkgs.runCommand "ccvm-egress-tests"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.getent
          egressWrapper
          egressFqdnWrapper
        ];
      }
      ''
        export CCVM=${egressWrapper}/bin/ccvm
        export CCVM_FQDNONLY=${egressFqdnWrapper}/bin/ccvm
        bash ${./egress.sh}
        touch "$out"
      '';

  # Image-paste bridge: assert the IMAGE-ONLY guarantee against the real reader extracted from
  # the wrapper source (no VM, no socat). See tests/clipboard.sh.
  clipboard =
    pkgs.runCommand "ccvm-clipboard-tests"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.gnugrep
          pkgs.coreutils
          pkgs.gawk
        ];
      }
      ''
        export WRAPPER_SRC=${../wrapper/ccvm.sh}
        export GUEST_SRC=${../guest/default.nix}
        bash ${./clipboard.sh}
        touch "$out"
      '';
}
