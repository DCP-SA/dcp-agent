# Changelog

This is the public changelog for DCP-owned changes to `dcp-agent`.

## [Unreleased]

### Pending - `fix(security): stop installer provider-key disclosure - PR #25`

**PR:** [#25](https://github.com/DCP-SA/dcp-agent/pull/25) (`agent/codex/task_60a2bfb04312-install-redaction`).

**What:** Hardens the root DCP provider installer so live provider keys are not
shown in terminal output or sudo rerun instructions.

- **Installer output:** Replaced provider-key prefix logging with a non-secret
  confirmation message.
- **Rerun help:** Replaced the sudo-cache failure command that interpolated the
  live key with placeholder-based `DCP_PROVIDER_KEY` instructions.
- **Env input:** Allows `DCP_PROVIDER_KEY` to supply the provider key without
  requiring `--key`.
- **Docs:** Updated the DCP agent technical spec so it no longer claims provider
  keys are partially logged or that provider machines receive master MiniMax or
  Telegram bot tokens.
- **Regression guard:** Added a root installer static test for provider-key
  echoing, rerun-help leakage, and bundled service credential shapes.
- **CI unblock:** Fixed two pre-existing repo-wide guard findings so this
  security PR can pass: explicit UTF-8 for the DCP first-run marker write and a
  guarded POSIX process-group kill signal in the process registry.
