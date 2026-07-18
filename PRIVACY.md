# Privacy

AgentGlance is local-only. It does not contain networking code, telemetry, analytics, advertising, or crash reporting.

## Data read

- running Claude Code, OpenCode, and Codex process metadata;
- process identifiers, working directories, terminal names, TTYs, and terminal session identifiers;
- AgentGlance hook events from Claude Code and OpenCode;
- Codex JSONL rollout files under `~/.codex/sessions`, which may contain conversation content;
- the configuration files modified when the user explicitly runs `agentglance install`.

AgentGlance scans Codex rollout lines locally but extracts and retains only session and lifecycle metadata. Prompt and response fields are discarded. It does not inspect project source files, environment secrets, or API credentials.

## Data stored

Transient session metadata is stored as JSON in `~/.agentglance/state`. The directory is mode `0700` and files are mode `0600`. State may include project paths, process IDs, status, timestamps, terminal identifiers, and a window-title hint.

No AgentGlance data leaves the Mac. Uninstall integrations with `agentglance uninstall`; this removes AgentGlance-owned hooks, plugin files, binaries, and state.
