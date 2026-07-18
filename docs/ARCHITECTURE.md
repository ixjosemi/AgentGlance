# Architecture

AgentGlance is a local, layered macOS application.

## Components

- `AgentGlanceApp` owns the SwiftUI lifecycle, notch panel, settings, and Codex observation timer.
- `AgentGlance` is the command-line entry point used by installation, hooks, notifications, and diagnostics.
- `AgentGlanceCore` contains domain models, persistence, integration parsers, process discovery, focus planning, and installation.

## Data flow

Claude hooks, the OpenCode plugin, the Codex watcher, and the process reaper normalize lifecycle information into versioned `AgentSession` documents. `StateRepository` atomically publishes those documents under `~/.agentglance/state`. `StateStore` observes the directory and exposes active sessions to the notch UI. Selecting a session creates a constrained focus action for tmux or a supported terminal.

## Trust boundaries

Hook payloads, JSONL rollouts, process output, state files, terminal metadata, and existing user configuration are untrusted. Readers bound input sizes and ignore symbolic links. State files use collision-free encoded names and private permissions. Process execution uses argument arrays and trusted executable locations; no runtime value is evaluated by a shell.

## Integrations

| Tool | Primary signal | Fallback |
| --- | --- | --- |
| Claude Code | lifecycle hooks | process scanner |
| OpenCode | local plugin events | process scanner |
| Codex CLI | rollout JSONL + notify | process scanner |

The reaper removes dead sessions and creates fallback state for detectable processes. Ghostty sessions are correlated to visible terminals so orphaned PTYs do not appear.

## State schema

Schema version 1 records tool, session ID, PID, lifecycle status, project path, timestamps, terminal context, and optional source. Unsupported schema versions fail closed.
