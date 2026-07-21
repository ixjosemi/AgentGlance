# Architecture

AgentGlance is a local, layered macOS application.

## Components

- `AgentGlanceApp` owns the SwiftUI lifecycle, notch panel, settings, and Codex observation timer.
- `AgentGlance` is the command-line entry point used by installation, hooks, notifications, and diagnostics.
- `AgentGlanceCore` contains domain models, persistence, integration parsers, process discovery, focus planning, and installation.

## Data flow

Claude hooks, the OpenCode plugin, the Codex watcher, and the process reaper normalize lifecycle information into versioned `AgentSession` documents. `StateRepository` atomically publishes those documents under `~/.agentglance/state`. `StateStore` observes the directory and exposes active sessions to the notch UI. Selecting a session creates a constrained focus action for tmux or a supported terminal.

## Presentation

The bar adapts to the selected screen (`NotchLayout.Presentation`). A display with a camera housing — `safeAreaInsets.top > 0` with auxiliary top areas present — keeps the status summary around the physical notch; every other display gets a compact notch-style drop centred in the menu-bar strip (`frame.maxY - visibleFrame.maxY`). Both hang directly from the screen edge with concave upper shoulders and rounded lower corners. A physical notch mirrors the larger compact wing into an empty black wing when needed, keeping both hardware shoulders visually symmetric. The collapsed summary is provider-agnostic and reports only the running, waiting, and blocked counts that are nonzero right now — same-size dots for waiting (gray) and blocked (red), a spinner for running. Expanding grows one continuous 800 pt silhouette around a centred 720 pt detail surface, giving its side curves enough horizontal sweep while every session retains room for provider, terminal title, project, Git branch or Convoy step, and elapsed time; both presentations share that single collapsed↔expanded spring. `ScreenSelection` chooses a stable display identity from the pointer by default, with a Settings option to prefer the focused window; it falls back through focused display, last valid display, then the first available screen. The controller checks that policy while the pointer moves, after activation/Space/display changes, relocates immediately, and defers relocation until an open menu closes. A `PointerMovementGate` keeps hover-expansion locked until the pointer actually moves after a jump — the bar appearing under a stationary pointer is not a hover. The panel only accepts mouse events inside the visible silhouette, so the rest of the menu bar remains clickable.

## Trust boundaries

Hook payloads, JSONL rollouts, process output, state files, terminal metadata, and existing user configuration are untrusted. Readers bound input sizes and ignore symbolic links. State files use collision-free encoded names and private permissions. Process execution uses argument arrays and trusted executable locations; no runtime value is evaluated by a shell.

## Integrations

| Tool | Primary signal | Fallback |
| --- | --- | --- |
| Claude Code | lifecycle hooks | process scanner |
| OpenCode | local plugin events | process scanner |
| Codex CLI | rollout JSONL + notify | process scanner |

The reaper removes dead sessions and creates fallback state for detectable processes. It also verifies native documents that have been quiet for a full five-second observation interval against the detected agent set, but requires two consecutive misses before removing a still-live PID. Daemon-hosted sessions are rebound by terminal identity when available, then by an unambiguous same-tool working-directory match. Ghostty sessions are correlated to visible terminals so orphaned PTYs do not appear. Every removal posts the Darwin state-change notification as well as changing the directory, so the UI refreshes without waiting for its polling fallback.

## State schema

Schema version 1 records tool, session ID, PID, lifecycle status, project path, timestamps, terminal context, and optional source. Unsupported schema versions fail closed.
