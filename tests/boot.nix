/*
  SPDX-License-Identifier: MIT
  Copyright (C) 2026 Jaxxen
*/

# Builds stub-`claude` ccvm wrappers for tests/boot.sh. Returns an attrset so the driver can
# build each posture by attribute:
#
#   nix build --impure -f tests/boot.nix open      # default: open egress, rw/overlay checks
#   nix build --impure -f tests/boot.nix egress     # opt-in allowlist, enforcement checks
#
# nixpkgs (pinned, allowUnfree) comes from the flake input; the guest/wrapper sources come
# from the working tree via the relative import of lib/mkccvm.nix — so the boot test
# exercises exactly the code you have checked out.
let
  flake = builtins.getFlake (toString ../.);
  pkgs = import flake.inputs.nixpkgs {
    system = builtins.currentSystem;
    config.allowUnfree = true;
  };
  stub = pkgs.writeShellScriptBin "claude" (builtins.readFile ./stub-claude.sh);
  mk = cfg: (import ../lib/mkccvm.nix { inherit pkgs; } ({ package = stub; } // cfg)).wrapper;
in
{
  open = mk { };
  # Allowlist example.com only; the stub probes both it (must reach) and a non-listed host
  # (must be blocked). api.anthropic.com is auto-included by the builder regardless. Setting
  # egressAllowlist also AUTO-DROPS the agent's sudo (agentSudo auto), so this posture doubles as the
  # check that a hardened-egress guest can't flush its own firewall (boot.sh asserts SUDO:dropped).
  egress = mk {
    egressAllowlist = [ "example.com" ];
    egressPorts = [ 443 ];
  };
  # Opt-in encrypted disk pool; the stub asserts /scratch is a writable dm-crypt mount.
  # 1 GiB leaves room for the LUKS header + an ext4 (sparse, so it costs ~nothing on disk).
  scratch = mk { vmDiskSize = 1; };
  # persistClaudeProjects: mounts the host ~/.claude/projects read-WRITE. The stub writes a marker
  # there (must reach the host) and one at the ~/.claude root (must NOT — projects-only scope), so
  # boot.sh asserts both the write-back functionality and that nothing outside projects/ persists.
  persist = mk { persistClaudeProjects = true; };
  # In-VM nix: the stub asserts /nix/store is a writable overlay and `nix` is present. Builds a
  # bigger guest closure (nix.enable), so this posture is slower to build the first time.
  nix = mk { nix.enable = true; };
  # In-VM nix + the encrypted disk pool: the initrd backs the /nix/store overlay UPPER with the
  # disk (not tmpfs), and /scratch shares that same pool. The stub asserts /nix/.rw-store is a
  # dm-crypt ext4 (RWSTORE:disk + RWSTORE:encrypted), the store is still an overlay, and /scratch
  # works. 1 GiB is enough for the LUKS header + ext4 (sparse, so ~free on disk).
  nixDisk = mk {
    nix.enable = true;
    vmDiskSize = 1;
  };
  # In-VM nix + an extra binary cache. The stub asserts the guest nix.conf carries the configured
  # substituter URL and its trusted public key (a real fetch from the cache is a human/network check;
  # example.invalid never resolves). Verifies nix.substituters/trustedPublicKeys reach guest nix.conf.
  nixSubst = mk {
    nix.enable = true;
    nix.substituters = [ "https://cache.example.invalid" ];
    nix.trustedPublicKeys = [ "cache.example.invalid:0000000000000000000000000000000000000000000=" ];
  };
  # Audit S-1 regression: nix.enable + egressAllowlist together (the real hardened config). With both,
  # the agent's sudo is dropped (agentSudo auto) AND it must NOT be a Nix trusted-user — otherwise it
  # could regain root via the daemon (post-build-hook) and `nft flush` the egress firewall, defeating
  # the drop. The stub reports TRUSTED:agent-not-trusted and the egress probes still show the firewall
  # holding. example.com is allowlisted; api.anthropic.com is auto-included.
  nixEgress = mk {
    nix.enable = true;
    egressAllowlist = [ "example.com" ];
  };
}
