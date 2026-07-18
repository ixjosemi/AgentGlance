# AgentGlance

**Know when your coding agents need you—without leaving the notch.**

AgentGlance is a quiet, native macOS indicator for Claude Code, OpenCode, and Codex CLI sessions. It shows active-session counts and attention state beside the MacBook notch, then returns you to the exact terminal tab or tmux pane with one click.

> **Preview status:** AgentGlance is pre-1.0 and currently distributed as source. The local build is ad-hoc signed; signed and notarized downloads will follow once the release pipeline is ready.

## Why AgentGlance?

- See only tools that currently have visible sessions.
- Notice permission requests, idle prompts, and completed turns.
- Focus the recorded Ghostty, iTerm2, Terminal, or tmux session.
- Keep all observation and state on your Mac.
- Run without telemetry, accounts, servers, or third-party Swift dependencies.

## Requirements

- macOS 14 Sonoma or newer;
- a MacBook with a notch for the intended UI placement;
- Swift 6.0 or newer to build from source;
- Node.js 20+ to run the OpenCode behavioral tests;
- Ghostty 1.3+ with AppleScript enabled, iTerm2, or Terminal.

Apple Silicon is the tested development platform. Intel builds have not yet been validated.

## Build from source

```bash
git clone https://github.com/ixjosemi/AgentGlance.git
cd AgentGlance
swift build
swift run agentglance-tests
./scripts/build-app.sh
open .build/AgentGlance.app
```

The script creates `.build/AgentGlance.app` with an ad-hoc signature for local development. Do not redistribute that bundle as an official release.

## Install integrations

Build the CLI and explicitly install the local integrations:

```bash
swift build -c release
.build/release/agentglance install
```

The installer:

- installs the CLI and hooks under `~/.agentglance/bin`;
- merges AgentGlance-owned Claude Code hooks into `~/.claude/settings.json`;
- installs `~/.config/opencode/plugins/agentglance.js` only when it can do so safely;
- adds a Codex `notify` entry only when no notification command exists.

Installation fails instead of replacing an unknown AgentGlance-named plugin or following symlinked managed directories.

To remove integrations and local state:

```bash
.build/release/agentglance uninstall
```

Then quit AgentGlance and delete the app bundle. Review your Claude or Codex configuration if you manually modified AgentGlance entries after installation.

## Terminal focus

| Host | Focus strategy | Notes |
| --- | --- | --- |
| Ghostty | exact terminal ID, then project/title fallback | Requires Ghostty 1.3+ |
| iTerm2 | native session ID | Uses iTerm2 AppleScript |
| Terminal | TTY | Uses Terminal AppleScript |
| tmux | validated pane ID, then host activation | `tmux` must be in a trusted standard install location |

macOS asks for Automation access the first time AgentGlance controls a terminal. If denied, enable it under **System Settings → Privacy & Security → Automation**.

## How it works

Claude hooks, an OpenCode plugin, the Codex rollout watcher, and a process fallback produce versioned session documents under `~/.agentglance/state`. The app observes that directory and renders active sessions. State is written atomically with user-only permissions.

See [Architecture](docs/ARCHITECTURE.md) for the full data flow and trust boundaries.

## Privacy and security

AgentGlance has no networking or telemetry. It stores local session metadata—including project paths, process IDs, timestamps, and terminal identifiers—but not prompts or model responses. Read [PRIVACY.md](PRIVACY.md) before installing integrations and [SECURITY.md](SECURITY.md) before reporting a vulnerability.

Treat `agentglance debug` output as private because it includes session and project metadata:

```bash
.build/release/agentglance debug
```

## Known limitations

- Codex rollout formats are not a stable public contract; unknown lines are ignored and the notify hook is the reliable turn-complete signal.
- Same-directory Codex sessions can be ambiguous when upstream events provide no PID or terminal identifier.
- The app currently has no signed/notarized binary release, automatic updater, app icon, or Homebrew cask.
- The behavioral runner is an executable because the minimal Command Line Tools environment used during early development did not ship XCTest or Swift Testing. Run it with `swift run agentglance-tests`.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md). New runtime behavior requires a failing behavioral test first. All pull requests must pass:

```bash
swift build
swift run agentglance-tests
./scripts/build-app.sh
```

## Trademark notice

AgentGlance is independent and is not affiliated with Anthropic, OpenAI, SST, Ghostty, Apple, or tmux. Product names and marks identify compatible tools only. See [NOTICE](NOTICE).

## License

[MIT](LICENSE) © 2026 Josemi Hernandez
