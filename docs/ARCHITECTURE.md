# Architecture

AgentGlance is a local, layered macOS application.

## Components

- `AgentGlanceApp` owns the SwiftUI lifecycle, notch panel, settings, and Codex observation timer.
- `AgentGlance` is the command-line entry point used by installation, hooks, notifications, and diagnostics.
- `AgentGlanceCore` contains domain models, persistence, integration parsers, process discovery, focus planning, and installation.

## Data flow

Claude hooks, the OpenCode plugin, the Codex watcher, and the process reaper normalize lifecycle information into versioned `AgentSession` documents. `StateRepository` atomically publishes those documents under `~/.agentglance/state`. `StateStore` observes the directory and exposes active sessions to the notch UI. Selecting a session creates a constrained focus action for tmux or a supported terminal.

## Presentation

The bar adapts to the screen it sits on (`NotchLayout.Presentation`). A display with a camera housing — `safeAreaInsets.top > 0` with auxiliary top areas present — keeps the notch-attached bar flush with the top edge, wings pinned against the camera. Every other display gets a floating pill: a pure-black capsule centered inside the menu bar strip, sized from the real menu bar height (`frame.maxY - visibleFrame.maxY`) so it never overlaps the windows beneath, with no phantom camera gap between the tools. Either way, the active tools split evenly across left and right (`NotchWingPlacement`): the left wing takes the first ceil(N/2) in canonical order, the right wing the rest. The panel follows the active screen (`NSScreen.main`, re-evaluated when the frontmost app changes and when display parameters change) and only accepts mouse events inside the visible silhouette, so the menu bar beside the pill stays clickable. A tool's menu opens when the pointer rests on its indicator for a short settle delay (150 ms) as well as on click; once any menu is open, hovering another tool switches immediately, and leaving the panel collapses after a grace period. Clicking the indicator of the already-expanded tool never collapses it — dismissal is by leaving the panel or clicking outside — which also keeps a hover expansion that fires mid-click from being toggled shut by the arriving mouse-up.

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
