# Technical Architecture (proposed)

**Status:** Direction for feasibility work; not a final technology commitment.

## Product boundary

The product is a macOS desktop shell. It is not a WoW addon and does not hook, inject into, or read memory from the game. The game is simply the target window that appears behind the shell.

```text
┌──────────────────────── macOS app ────────────────────────┐
│ Workspace coordinator                                    │
│  ├─ AppKit overlay/panel windows + input hit regions      │
│  ├─ Panel web/native views                                │
│  │   ├─ Browser panel (CEF / Chromium)                    │
│  │   ├─ Agent panel                                       │
│  │   └─ Later: editor, notes, tools                       │
│  ├─ Profiles/layout persistence                          │
│  └─ Menu bar, shortcuts, recovery                         │
└───────────────┬───────────────────┬──────────────────────┘
                │ local provider API │ provider-specific protocol
         ┌──────▼──────┐      ┌─────▼───────────────────────┐
         │ Codex App   │      │ Claude/local agent runtime │
         │ Server      │      │ or another supported tool  │
         └─────────────┘      └─────────────────────────────┘

The target application (WoW Forever beta, WoW, or another app) remains a
separate process underneath the overlay. There is no game process connection.
```

## Windowing approach

The feasibility build now uses separate panel-sized AppKit windows for the browser and terminal. Uncovered screen space has no overlay window and passes pointer input to the app below. Each borderless panel owns only its own rectangular hit region; rounded corners and shadows still need a real WoW check. The earlier full-monitor canvas and focus-probe window have been removed.

The browser uses a locally vendored CefSwift 0.1.0 integration to host Chromium Embedded Framework in a separate AppKit panel. The local patch exposes DevTools Protocol commands for device metrics. Native-parented CEF DevTools traps on macOS, so the inspector uses CEF's ephemeral loopback debugging endpoint and loads its frontend in a second embedded CEF browser inside the panel. This keeps navigation controls and panel geometry under the native shell. CEF initializes before AppKit and is packaged with its framework and helper processes. Its profile lives at `~/Library/Application Support/WoWIDEFeasibility/Chromium`, independent of Chrome and Brave. The browser is a feasibility implementation; the agent UI technology remains a later decision. Keep web content and window-management responsibilities separate so a page cannot silently change global window/input policy.

The local terminal is a separate AppKit panel hosting GhosttyKit through a locally patched Termini `NSHostingView` and a Bash login shell on a pseudo-terminal. GhosttyKit is a checksum-pinned static XCFramework; its source wrapper disables the upstream demo behavior that activates the host app on surface creation and click. The shell retains the current user's permissions and continues running while its panel is hidden or minimized. A click in its terminal viewport explicitly grants keyboard focus. Outside-app clicks and key-window resignation clear that focus without activating WoW. The browser uses a matching outside-click release and accepts page `focusin` requests only after a recent click in its own web view, so delayed script messages cannot retake keyboard focus from another app.

Prototype at least these configurations:

1. A non-activating panel receiving first mouse input.
2. A panel that activates on click for standard keyboard/text entry.
3. Two independent panel windows over a normal app and over WoW Forever beta.
4. A full-screen/Spaces case, plus borderless/windowed fallback.

Document which interactions activate the overlay process and which keep the game as the active app. Text input can take keyboard focus from WoW. Test native text controls and CEF page controls independently. Keyboard control is sequential: a panel owns keyboard focus during text entry, then a tested user action returns focus to the game. Both panels use custom header dragging to avoid the system title-bar tracking loop. Each panel has its own nonactivating minimize launcher. AeroSpace provides target-window workspace membership and CoreGraphics provides bounds; a background poll keeps panels anchored to the selected WoW window and hides them when its workspace is not visible. Native fullscreen or unmanaged windows fall back to CoreGraphics on-screen membership. When the selected target is not running, requested panels remain available at their last positions for standalone debugging.

## Target app and profiles

- Profile stores target app identity (bundle ID/process name where available), display, panel bounds, z-order, opacity, and active panels. Browser session data and agent thread references are stored separately from geometry and have explicit retention/clear behavior.
- The menu-bar process observes the selected app's launch, activation, and termination. It may show windows without deliberately activating itself, remains resident when the panel is hidden, and hides the overlay after the selected app exits. A manual hide suppresses auto-show until target termination or a manual show.
- Store the selected target's exact app bundle path; use bundle ID only as a unique fallback if that path disappears. Optional Start at Login is explicitly user-enabled from the packaged app through `SMAppService.mainApp`.
- Manual positioning works even when the app cannot be identified or tracked.
- Optional follow-target-window behavior is isolated behind a target-window tracker. It must degrade to fixed screen coordinates rather than fail the core overlay.
- Do not parse WoW client memory or server internals. Game-specific helpers can later be optional plugins using documented addon/companion mechanisms.

## Panel/provider boundary

Each panel declares:

- Stable provider ID and display name.
- Supported panel types and minimum size.
- How it starts, reconnects, and shuts down.
- Its user-visible state (connecting, ready, working, waiting for approval, error).
- A small set of explicit actions and events.
- Required permissions and data retention behavior.

The shell owns panel geometry, input routing, persistence, global shortcuts, and provider lifecycle. Providers own their specific agent/browser/tool protocol. Provider messages should be typed, versioned, bounded, and local to the machine.

## Codex integration

Use Codex App Server as the first provider candidate. It exposes a long-lived JSON-RPC interface for a custom client, including thread/request events and approval handling. Confirm authentication, streaming, cancellation, and approval behavior against the supported Codex version before locking the adapter. Start with read-only access in a user-selected workspace; any write-capable mode must be visible and preserve explicit approval. Keep App Server behind a provider adapter; do not expose raw agent protocol to panel HTML.

## Claude integration

Investigate supported Claude Code/local APIs during the provider spike. Do not build against undocumented private IPC. If no stable local client interface is appropriate, phase Claude after the first Codex panel or use its supported CLI/SDK with a bounded adapter.

## Trust and security boundaries

- Bind any app-owned local socket to loopback only, or prefer a Unix domain socket with restrictive permissions.
- Validate the calling process where practical; use a random per-launch capability token for local webview-to-host IPC.
- Expose only provider commands the panel needs. No arbitrary shell execution through the overlay bridge.
- Treat web pages, agent output, and extension packages as untrusted content.
- Keep credentials in the OS keychain or provider's own auth flow; redact them from logs.
- Require explicit user approval for agent actions that request it. Make pending approvals visually distinct.
- The overlay must not hide itself from recordings or claim privacy from screen capture.

## Licensing and attribution

- Proposed project license: MIT, pending maintainer/user confirmation.
- Track third-party source, license, modified files, and required notices in `THIRD_PARTY_NOTICES.md` before copying code.
- Evaluate Peekaboo as a Mac UX/windowing reference and possible implementation donor; audit its current source and license before reuse.
- Astrum is a product/UX reference only unless a compatible source license is found.
- Do not copy code from projects under Elastic License 2.0 or another incompatible/restricted license without explicit legal review and a deliberate license choice.

## Technical spikes and evidence

1. Hit testing over WoW Forever beta: test panel content, handle, corners, shadows, gaps, overlaps, and exposed game areas with separate panel windows.
2. Focus and keyboard: first mouse click, native text entry, CEF page text entry, app activation, game focus recovery, hide shortcut, and menu-bar fallback.
3. Spaces/fullscreen/window levels: test actual client and selected Mac version in windowed, windowed-fullscreen/borderless, and macOS fullscreen Space as distinct configurations.
4. CEF: native view rendering, first click, text input, external navigation, localhost HMR, docked DevTools, device metrics, tabs, dedicated profile, memory footprint, and helper-process lifecycle.
5. App tracking: target movement, window resize, game restart, multi-monitor changes.
6. Provider: stream a Codex response, cancel it, show an approval request, restart connection; verify read-only default and selected workspace.
7. License audit: verify donor files and dependency licenses before importing code.

## Sources

- Apple `NSWindow` mouse and ordering APIs: https://developer.apple.com/documentation/appkit/nswindow
- Chromium Embedded Framework: https://chromiumembedded.github.io/cef/general_usage
- CefSwift: https://github.com/Rajaniraiyn/CefSwift
- Codex App Server: https://openai.com/index/unlocking-the-codex-harness/
- Peekaboo (reference candidate): https://github.com/JakeB-5/peekaboo
- Interceptor overlay docs (technical reference, restricted repository license): https://github.com/Hacker-Valley-Media/Interceptor/blob/main/docs/native/overlays.md
