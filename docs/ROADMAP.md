# Roadmap and Delivery Plan

Planning sequence only. Dates and effort estimates are intentionally omitted until the technical spikes and technology choice are complete.

## Phase 0 — product and donor audit

- Confirm the working title, project license, minimum macOS version, and distribution plan before public release. Codex App Server is the initial provider candidate.
- Record the exact WoW Forever beta client/build, macOS version/build, Mac chip, display setup, and in-game display mode for each compatibility run.
- Inspect Peekaboo source, license, build/release state, window lifecycle, and hit-testing approach.
- Try Astrum if accessible; write down useful WoW-oriented UX observations without treating it as a source donor.
- Produce a third-party code/dependency inventory before copying any implementation.

**Exit:** chosen base strategy is documented: new native shell with selected donor components, or a fork/adaptation with a clear maintenance case.

## Phase 1 — input/focus proof of concept

- Create separate panel-sized native AppKit windows so uncovered game space remains directly clickable.
- Add selected-app launch detection, menu-bar residency, automatic show/hide behavior, manual-hide suppression, and the menu/global-hotkey controls to the feasibility shell.
- Test click-through at panel centers, edges, rounded corners, shadows, gaps, and overlaps; test click inside, first-click behavior, native text focus, game focus restoration, emergency hide, menu-bar recovery, and restart recovery.
- Test WoW Forever beta in the user's everyday display mode and at least one fallback mode, recording the exact mode and client build.
- Test windowed, windowed-fullscreen/borderless, macOS Spaces/fullscreen, and multi-display behavior as distinct cases. Publish no broad compatibility claim for untested cases.
- Save screen recordings or notes only with user consent; record reproducible manual steps and known failures.

**Exit:** interaction contract is demonstrated and documented in a reproducible configuration; panel-only hit testing and a recovery path work; unverified modes are recorded. No blocker remains hidden behind a browser/agent UI.

## Phase 2 — shell MVP

- Menu-bar app lifecycle and preferences.
- Exact target-app selection and automatic show on launch, with an opt-in login item and clear manual override behavior.
- Reusable panel container and one saved workspace layout.
- Drag/resize/collapse/restore, opacity, configurable shortcuts, emergency hide.
- Optional target app profile and resilient manual placement.
- Diagnostics for panel/window state and connection health.
- Internal `.app` packaging with local ad-hoc signing and instructions; public distribution signing/notarization remains a later decision.

**Exit:** shell reliably opens, overlays, hides, and restores over WoW Forever beta and a normal app.

## Phase 3 — first real panels

- Embedded Chromium browser panel using CEF, with general HTTP(S) navigation, tabs, docked DevTools, responsive presets, and an isolated clearable profile. The feasibility version is present; live focus, HMR, and performance checks remain before release.
- Embedded GhosttyKit terminal panel through Termini with a Bash pseudo-terminal and passive focus patch. The feasibility version builds; runtime focus and window-follow behavior need a user-present check.
- First agent provider: Codex App Server candidate; verify authentication, thread list/new thread, streaming, cancellation, errors, read-only default, and approval UI before finalizing the adapter.
- Local provider bridge and token/permission boundaries.
- Browser and agent panel state persistence.

**Exit:** user can browse, ask the agent a prompt, observe output/approval, and return to play without losing the workspace.

## Phase 4 — hardening and public preview

- Performance and memory profiling during normal WoW gameplay.
- Test client relaunch, display change, sleep/wake, agent outage, and version upgrade.
- Accessibility/keyboard navigation and readable opacity presets.
- License notices, project setup guide, security disclosure, issue templates, and reproducible build instructions.
- Sign/notarize if distribution strategy requires it.

**Exit:** publish a clearly labeled beta with supported configuration, known limitations, and easy recovery/uninstall.

## Phase 5 — integrations and polish

- Add Claude Code as a second agent after the Codex provider path is stable.
- Add code/diff preview, notes, and optional local tool panels.
- Add named layouts and target-specific placement profiles.
- Consider an optional addon/companion context bridge only after the generic overlay succeeds.

## Release gates

- **No basic overlay release** until panel-only hit-testing and a recovery path work on target Mac.
- **No game compatibility claim** beyond configurations tested and recorded.
- **No source import** until license and attribution are recorded.
- **No agent approval bypass**; approval requests must remain visible and user-controlled.
