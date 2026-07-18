# Agent Guide

## Scope

AgentGlance is a native macOS 14+ Swift package with three targets: the notch app, the `agentglance` integration CLI, and a dependency-free behavioral test runner.

## Commands

```bash
swift build
swift run agentglance-tests
./scripts/build-app.sh
```

Run all three before proposing a pull request. The app bundle is written to `.build/AgentGlance.app` and must never be committed.

## Engineering rules

- Add a failing behavioral test before changing runtime behavior.
- Keep integrations local-only; do not add telemetry or network access without explicit product approval and privacy documentation.
- Treat process metadata, hook payloads, rollout files, state files, filesystem paths, and terminal identifiers as untrusted input.
- Use absolute executable paths or a fixed allowlist. Never execute strings through a shell.
- Preserve user-owned configuration. Installation must fail rather than overwrite an unknown integration file.
- State belongs in `~/.agentglance/state`, with directory mode `0700` and file mode `0600`.
- Never commit credentials, signing certificates, provisioning profiles, notarization passwords, `.env` files, generated apps, or local session data.
- Keep source under `Sources/` and behavioral tests under `Tests/AgentGlanceCoreTests/`.

## Public interfaces

`AgentGlanceCore` is an internal module shared by the app and CLI, not a supported library product. Changes to the state schema or installed integration format require explicit documentation and tests.
