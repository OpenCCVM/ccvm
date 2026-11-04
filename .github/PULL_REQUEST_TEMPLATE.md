<!-- Keep the PR focused. Describe the WHY, not just the what. -->

## What & why


## Checklist

CI runs `nix flake check` (host-side guarantees, guest build, shellcheck) automatically, against
both the pinned nixpkgs and `nixos-unstable`. The
full-boot smoke test (`tests/boot.sh`) needs a real VM and is **not** in CI — so if your change
touches the **guest, wrapper, or boot path**, you must run it locally on a Nix+KVM box and paste
the result here. (See CLAUDE.md → "Definition of done".)

- [ ] `nix flake check` is green (CI on this PR, or run locally)
- [ ] **Ran `bash tests/boot.sh` on a Nix+KVM box** — pasted the `N passed, M failed` line below; **or** N/A (docs / CI-only change, no guest/wrapper/boot impact)
- [ ] Touches the TTY (zsh/ZLE/terminfo/`ssh -tt`)? Did a human `ccvm --shell` pass — resize, `vim`, `less`, vi-mode — since terminal fidelity isn't automated
- [ ] Security invariants still hold (no secret to disk/argv/seed; host key pinned; only the CWD shared) — see CLAUDE.md "Security invariants"
- [ ] Commit trailer is the exact ccvm form: `Co-authored-by: Claude <noreply@anthropic.com>`

<!-- boot.sh result (paste the summary line, e.g. "36 passed, 0 failed"), or "N/A — <why>": -->
