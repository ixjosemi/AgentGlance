# Architecture

AgentGlance is a local, layered macOS application.

## Components

- `AgentGlanceApp` owns the SwiftUI lifecycle, notch panel, settings, and Codex observation timer.
- `AgentGlance` is the command-line entry point used by installation, hooks, notifications, and diagnostics.
- `AgentGlanceCore` contains domain models, persistence, integration parsers, process discovery, focus planning, and installation.

## Data flow

Claude hooks, the OpenCode plugin, the Codex watcher, and the process reaper normalize lifecycle information into versioned `AgentSession` documents. `StateRepository` atomically publishes those documents under `~/.agentglance/state`. `StateStore` observes the directory and exposes active sessions to the notch UI. Selecting a session creates a constrained focus action for tmux or a supported terminal.

## Presentation

The bar adapts to the selected screen (`NotchLayout.Presentation`). A display with a camera housing — `safeAreaInsets.top > 0` with auxiliary top areas present — keeps the status summary around the physical notch; every other display gets a virtual notch centred within its menu-bar strip. Both use the same concave upper-shoulder and rounded lower-corner radii (`HangingNotchMetrics`); expansion preserves those arcs and adds straight vertical sides between them. A physical notch mirrors the larger compact wing into an empty black wing when needed, keeping both hardware shoulders visually symmetric while placing each counter 2 pt from the outer edge and 14 pt clear of the camera cutout; virtual pills retain 18 pt horizontal padding. The collapsed summary is provider-agnostic and reports only the running, waiting, and blocked counts that are nonzero right now — same-size dots for waiting (gray) and blocked (red), and a spinner for running. Expanding grows an 800 pt silhouette around a centred 784 pt detail surface with 8 pt shell and card insets, while every session retains room for provider, terminal title, project, Git branch or Convoy step, and elapsed time; both presentations share that single collapsed↔expanded spring. `ScreenSelection` chooses a stable display identity from the pointer by default, with Settings options to prefer the focused window or show independent panels on all connected displays. The controller checks the selected policy while the pointer moves, after activation/Space/display changes, relocates immediately, and defers a single-display relocation until an open menu closes. A `PointerMovementGate` keeps hover-expansion locked until the pointer actually moves after a jump — the bar appearing under a stationary pointer is not a hover. The panel only accepts mouse events inside the visible silhouette, so the rest of the menu bar remains clickable.

## Trust boundaries

Hook payloads, JSONL rollouts, process output, state files, terminal metadata, and existing user configuration are untrusted. Readers bound input sizes and ignore symbolic links. State files use collision-free encoded names and private permissions. Process execution uses argument arrays and trusted executable locations; no runtime value is evaluated by a shell.

## Integrations

| Tool | Primary signal | Fallback |
| --- | --- | --- |
| Claude Code | lifecycle hooks | process scanner |
| OpenCode | local plugin events | process scanner |
| Codex CLI | rollout JSONL + notify | process scanner |

The reaper removes dead sessions and creates fallback state for detectable processes. It also verifies native documents that have been quiet for a full five-second observation interval against the detected agent set, but requires two consecutive misses before removing an otherwise live PID. Process identity combines PID with kernel start time, so PID reuse and zombies cannot preserve old state. Daemon-hosted sessions are rebound globally one-to-one by terminal identity when available, then by an unambiguous same-tool working-directory match. Basic libproc reconciliation runs before optional, time-bounded Ghostty enrichment. Convoy metadata changes are watched directly; a verified run keeps a one-heartbeat final-state grace after its process exits. Every removal posts the Darwin state-change notification as well as changing the directory, so the UI refreshes without waiting for its polling fallback.

## State schema

Schema version 1 records tool, session ID, PID, lifecycle status, project path, timestamps, terminal context, and optional source. AgentGlance may add an optional `process_identity` containing that PID and its kernel start time in microseconds; older integration documents remain valid and are enriched during reconciliation. Unsupported schema versions fail closed.
