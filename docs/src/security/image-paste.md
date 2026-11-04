<!-- SPDX-License-Identifier: MIT
  -- Copyright (C) 2026 Jaxxen
  -->

# Image-paste bridge

`clipboard.images` (default-on) makes Ctrl+V **image paste** work inside the VM, like native
`claude`.

## The problem

Claude Code reads pasted images by shelling out to `xclip` / `wl-paste`. The guest has no
X/Wayland, so without a bridge Ctrl+V image paste **silently no-ops**.

## How the bridge works

ccvm restores image paste over the **existing SSH connection** — no new network hole:

1. **Guest shims.** Fake `xclip` / `wl-paste` (`guest/default.nix`, gated on `cfg.clipboard.images`)
   connect to `cfg.clipboard.port` (9180) on guest loopback, send a one-word request
   (`TARGETS` / `image/png` / `image/bmp`), and stream the reply to stdout.
2. **Reverse tunnel.** The wrapper's `ssh -tt` adds `-R 127.0.0.1:9180:127.0.0.1:<hostport>`. sshd
   is `AllowTcpForwarding = "remote"` **pinned by `PermitListen 127.0.0.1:9180`** — exactly one
   reverse forward to one loopback port; no local/dynamic forwarding, and forwarding is
   client-requested so the agent can't set up its own.
3. **Host server.** A `socat` listener (a wrapper `runtimeInput`) starts before connecting. Per
   request it runs the **host's** `wl-paste` / `xclip` for **image targets only**. The `case` arms
   are literal MIME types — a guest request can't widen to `text/*` or inject a command.

## Why this doesn't weaken the boundary

The bridge rides **loopback + the established SSH connection** (`oifname lo accept` +
`ct state established`), punching **zero holes** in the egress firewall — a prompt-injected agent
can't repurpose the one pinned forward.

It is **image-only, enforced host-side** — the server never reads `text/plain`, and the shims never
*write* the host clipboard — so host clipboard **text** (where passwords/tokens live) **never
crosses**. This makes the bridge strictly *less* exposure than native `claude`.

## Honest residual

Under **open egress**, a prompt-injected agent can *pull* any clipboard image at any time
(pull-on-demand, not just on user paste) and exfiltrate it — same class as the project tree. Under
hardened egress it can read the image but can't send it off-box.

The bridge is **inert** when the host has no `wl-paste` / `xclip`. `CCVM_CLIPBOARD_IMAGES=0` only
disables the wrapper-side wiring (it can't conjure missing guest shims / the sshd rule).

The image-only guarantee is regression-tested against the **real** reader extracted from the wrapper
(`tests/clipboard.sh`, the `clipboard` flake check) — no VM needed. macOS host support is future.
