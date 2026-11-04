/*
  SPDX-License-Identifier: MIT
  Copyright (C) 2026 Jaxxen
*/

# Hardened, single-purpose sshd. This is the (invisible) transport the host wrapper
# uses to drop the user straight into Claude Code with a real PTY — chosen over a
# serial/virtio console specifically because SSH propagates termios and SIGWINCH, so
# resize / vim / less / full-screen TUIs behave exactly as on the host (see CLAUDE.md,
# "SSH transport, not the serial console").
#
# Key-only, no passwords, no root, one ForceCommand. The host key and authorized_keys
# come from the per-run seed (installed by ccvm-seed.service), so the client can pin the
# ephemeral host identity with StrictHostKeyChecking=yes.
{ config, lib, ... }:
let
  cfg = config.ccvm;
in
{
  services.openssh = {
    enable = true;
    # Do not let NixOS generate persistent host keys: ccvm-seed.service installs the
    # per-invocation key the wrapper pinned in its known_hosts.
    hostKeys = [ ];
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      AuthenticationMethods = "publickey";
      AuthorizedKeysFile = "/etc/ccvm/authorized_keys";
      # Receive the Anthropic API key over the encrypted channel only (never argv/disk).
      AcceptEnv = [ cfg.apiKeyVariable ];
      X11Forwarding = false;
      # Remote (-R) forwarding ONLY when the image-paste bridge is on, and even then pinned by
      # PermitListen (below) to the single clipboard loopback port. "remote" still forbids local
      # (-L) and dynamic (-D) forwarding, and forwarding is a CLIENT-requested feature — only the
      # key-holding wrapper can request the tunnel, never the in-guest agent. Bridge off => the
      # original hardened "no". See CLAUDE.md, "Image paste".
      AllowTcpForwarding = if cfg.clipboard.images then "remote" else "no";
      AllowAgentForwarding = false;
    };
    extraConfig = ''
      HostKey /etc/ssh/ssh_host_ed25519_key
      ForceCommand ${cfg.launcherPackage}/bin/ccvm-guest-launch
    ''
    + lib.optionalString cfg.clipboard.images ''
      PermitListen 127.0.0.1:${toString cfg.clipboard.port}
    '';
  };

  # sshd must not start until the seed is mounted and the host key + authorized_keys
  # are in place; otherwise the first connection races key installation.
  systemd.services.sshd = {
    after = [ "ccvm-seed.service" ];
    requires = [ "ccvm-seed.service" ];
  };
}
