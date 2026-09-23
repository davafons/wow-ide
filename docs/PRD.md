# Product Requirements Document

**Project:** WoW IDE (working title)  
**Status:** Draft for product and technical validation; overlay direction confirmed, input/focus feasibility unproven  
**Platform:** macOS first  
**First target:** WoW Forever beta  
**Product type:** Open-source desktop overlay and agent workspace

**Validation baseline (2026-09-23):** macOS 26.6 (25G72), Apple M2 Pro, two displays (5K/144 Hz and 4K/60 Hz). Blizzard's latest beta note located during this revision is WoW Forever 1.60.1 Build 69977; it includes Mac display and stability fixes. This records the available test environment, not a claim that the overlay has been tested against that build. Re-record the exact game build, display mode, resolution, scaling, and active display for every compatibility run.

## 1. Summary

Build a lightweight Mac desktop workspace that floats useful tools over a running application. The first use case is playing WoW Forever beta while keeping a Codex coding agent, a web browser, and later code/editor views available in small panels. Claude Code is a later provider unless the Codex integration spike finds no supported local integration path.

The overlay must be generic at its core. It should operate as a normal macOS windowing application and must not require a WoW addon, game-memory access, injection, or a special game build. WoW Forever beta is the initial compatibility target; regular WoW and other foreground applications are intended follow-on targets.

The core interaction goal is spatial pass-through: uncovered parts of the overlay do not intercept clicks, while a click on a visible panel operates that panel. The prototype must establish what focus and typing behavior macOS and WoW allow before the product promises seamless play while interacting with a panel. In passive mode, non-text panel clicks and drags should leave keyboard input with WoW. Text entry temporarily takes keyboard input; finishing editing should return it to WoW. Simultaneous game controls and panel text entry are out of scope.

## 2. Problem

Players who work with coding agents, reference sites, notes, or other desktop tools have to switch away from the game and reconstruct context. Existing pieces solve only slices of this workflow: game chat overlays, floating browsers, or generic click-through windows. The desired product combines a reusable transparent workspace with interactive panels and agent integrations.

## 3. Product principles

1. **Game-agnostic foundation.** Target windows are selected by the user or detected as ordinary desktop windows; game APIs are optional integrations, never required for the overlay to render.
2. **Play remains in control.** Empty overlay space passes pointer input through. No hidden automation sends game actions.
3. **Panels are real tools.** Browser and agent panels support normal scrolling, controls, text entry, and accessible keyboard focus.
4. **Local-first.** Agent processes and UI bridge run on the user's Mac unless an explicitly selected integration requires a service.
5. **Open by design.** The application and its integration interfaces are developed in public under a permissive license, subject to third-party licenses.
6. **Build on verified work.** Reuse compatible open-source code with attribution; use closed or restricted projects as product references only.

## 4. Target users and jobs

### Primary user

A Mac player of WoW Forever beta who wants an agent and reference tools in view while playing.

### Core jobs

- Keep a small Codex conversation visible while the game remains visible.
- Search the web without minimizing the game.
- Click and type in a panel, then return to gameplay without losing panel state.
- Arrange, resize, fade, hide, and restore a small collection of panels.
- Reuse the same workspace over regular WoW or another application.

## 5. Goals

- Deliver a dependable, low-friction overlay on macOS.
- Prove panel-only pointer targeting and practical focus behavior with WoW Forever beta.
- Ship a browser panel and one supported coding-agent integration in the first useful release.
- Make additional agent and app integrations possible without rewriting overlay/window management.
- Keep normal desktop use available when no game is running.

## 6. Non-goals for the first release

- Reimplementing WoW addons or a web browser engine.
- Embedding the full native Claude or Codex desktop application as a child window.
- Reading game memory, injecting into the game process, or automating gameplay.
- Requiring an addon to communicate with the desktop app.
- Guaranteeing compatibility with every game, graphics mode, display configuration, or Mac before testing.
- Windows/Linux support in the initial release.
- Hiding the overlay from screen recording or screen sharing.

## 7. MVP scope and requirements

### P0 — feasibility prototype

- Native floating overlay above a selected target application, starting with a small AppKit test view before embedded Chromium.
- At least one visible interactive panel plus a broad uncovered region of the target app.
- Demonstrate that clicks in panel content, panel handles, rounded corners, shadows, gaps, and uncovered target areas reach the intended recipient. A translucent appearance alone does not count as click-through proof.
- Demonstrate text entry in a native text field and record whether panel interaction activates the overlay app or changes WoW keyboard focus.
- Test an emergency hide shortcut while WoW is frontmost. Keep a menu-bar hide command as a fallback if a global shortcut cannot be registered or is intercepted.
- Run the test in the user's ordinary Forever display mode and at least one alternative mode; record the exact in-game mode rather than describing it only as fullscreen.
- Record exact Forever build, macOS version/build, Mac chip, display layout/scaling, game resolution/mode, overlay placement, test steps, focus changes, missed clicks, rendering faults, and recovery results.
- P0 is a feasibility gate, not a shipping compatibility claim. Passing requires repeatable panel-only input, a reliable path back to gameplay, and no unresolved input trap. Untested configurations remain unknown.

### P1 — first useful release

- Workspace with draggable/resizable panels and saved position/layout.
- Browser panel based on embedded Chromium (CEF), with general HTTP(S) navigation, tabs, docked DevTools, and responsive previews.
- One Codex panel using a documented local integration path, validated during the provider spike.
- Panel-level opacity/background controls with readable default contrast.
- Show/hide and emergency-hide shortcuts, configurable to avoid common game bindings.
- Menu-bar-resident app lifecycle: closing/hiding panels leaves the app running; Quit is explicit.
- User selects the exact target application bundle. When that app is already running or launches, the overlay can show automatically without deliberately activating the overlay app. A manual hide suppresses auto-show until the target exits or the user manually shows the overlay.
- Optional user-controlled Start at Login using the macOS login-item service; never register it during packaging or enable it without the user's action.
- Menu-bar entry for show/hide, target selection, layout restore, startup preference, and quit.
- Simple app profiles (for example WoW Forever beta, regular WoW, general desktop) storing target and layout preferences only.
- Clear permission and connection status for every integration.
- A visible, user-selected Codex working directory. Start in read-only mode; any write-capable mode or approval is explicit and visible. Never approve agent actions silently.
- Clear behavior for cancel, disconnect, app quit, and pending approvals. Quitting the overlay must not be represented as cancelling work unless the provider confirms cancellation.

### P2 — extensible workspace

- A documented provider interface for additional agents and local tools.
- Add a second agent integration (Codex or Claude, whichever is not in P1).
- Additional panels such as notes, task lists, code/diff preview, and logs.
- Multiple named layouts and per-target layouts.
- Optional contextual integrations where supported and expressly enabled.

## 8. Interaction model

### Default state

The overlay is visible, but only panel-shaped areas receive pointer events. Uncovered space passes clicks to the target app. Users should not need to toggle a whole-screen click-through mode for ordinary play. The feasibility prototype must prove this behavior with real clicks; visual transparency or a mock hit-test is insufficient.

### Panel interaction

A click inside a panel should interact with that panel. In passive mode, clicking or dragging non-text parts should preserve WoW keyboard input. Clicking a text field may temporarily move keyboard focus to the panel; Return or a click outside the field should restore it to WoW. The prototype must measure and document what macOS and the game actually do. Do not claim simultaneous game key input and text entry to a panel. Test native text input separately from CEF page input.

### Recovery and safety

The intended emergency shortcut hides the complete overlay while WoW is frontmost; its registration and behavior are P0 test gates, not assumed macOS behavior. A menu-bar command is the fallback and restores the overlay. Panels must not trap the cursor or keyboard after being hidden. Panel dragging uses a deliberate title/handle region so content clicks are not accidentally interpreted as moves. The overlay stays visible in screen recording; it does not simulate keyboard/mouse input into WoW.

### Visual behavior

- Adjustable panel opacity; text and controls remain readable at default settings.
- Uncovered game space is not covered by an overlay window or dark tint.
- Panels may be minimized/collapsed independently.
- Avoid motion, flashing, and automatic content changes that obscure gameplay.
- Use restrained transitions and HUD styling; honor macOS Reduce Motion and Reduce Transparency preferences.

## 9. Functional requirements

### Workspace and windows

- Create, close, move, resize, minimize, and restore panels independently. Each minimized panel has its own nonactivating restore control; a global recovery shortcut can hide both panels.
- Save geometry and per-panel state between launches.
- Follow a selected target window where technically possible; retain a stable manual positioning mode as fallback.
- Target following is best-effort. The P0 shell may use manually positioned screen coordinates; selecting/following an individual WoW window is not a release prerequisite until its reliability is demonstrated.
- Support multiple displays and recover from display reconnect/resolution changes.
- Offer an always-available hide/quit path.
- Observe the selected app's launch, activation, and termination. Keep the menu-bar process alive when the target exits; auto-show on a later target launch, but do not re-show after a manual hide until the target exits or the user manually shows it.
- Store the exact selected bundle path locally and use bundle-identifier matching only as a unique fallback if that path no longer exists.
- Offer opt-in Start at Login from the packaged app; report approval or registration errors in the menu. The package script does not register a login item.

### Browser

- Navigate, back/forward, reload, scroll, and accept normal web text input. Reload bypasses cache for local development. Support up to eight independent tabs and dock the Chromium DevTools frontend inside the browser panel.
- Provide an HTTP(S) address field for local and public sites. The feasibility build opens on a built-in start page and supports multiple tabs. Search suggestions and bookmarks are outside this pass.
- Keep browser data in a dedicated, clearly disclosed CEF profile with a user-accessible clear-data action. The feasibility build persists cookies and cache by default for developer-session continuity and clears them on the next launch when requested.
- Provide desktop, responsive, phone, and tablet viewport presets using Chromium device metrics and touch emulation. User-agent emulation remains a later decision.
- Do not forward page content or browser credentials to an agent automatically. The user may explicitly copy/paste selected content into an agent prompt.
- The initial browser is for reference browsing, not a full general-purpose browser: popup windows, downloads, file uploads, and site permission prompts are blocked or handed off to the system browser until separately specified.

### Terminal

- Offer an embedded local shell panel with a pseudo-terminal, native resize, saved position, and an individual minimize control. The feasibility build embeds GhosttyKit through a patched Termini wrapper and opens `/bin/bash -l` in the user's home directory.
- Give the terminal keyboard focus only after a click in its viewport. Clicking another application must release that focus without activating WoW; clicking non-text terminal content may return focus to WoW when WoW was frontmost before terminal input.
- Preserve the shell process when the panel is hidden or minimized. Commands run with the user's normal local permissions.

### Agent panels

- Start/resume a thread, submit a prompt, stream output, cancel generation, and show connection status.
- Render markdown and code with copy controls.
- Show tool activity and approval requests distinctly; never silently approve privileged actions.
- Keep provider authentication and sandboxing owned by the official local agent runtime where possible.
- Agent bridge is local-only and should use a narrow, documented protocol.
- Show the selected workspace, permission/sandbox mode, and provider approval state in the panel. Default to read-only access; do not expose arbitrary shell execution through the overlay's own bridge.
- Persist thread references separately from layout. Do not persist credentials or full prompts in diagnostics. Define provider-specific history retention before release.

### Persistence and retention

| Data | Owner/location | Default behavior |
|---|---|---|
| Workspace layout, panel bounds, opacity, shortcuts, target profile | Overlay app's local settings | Persist across app restarts; recover safely if a display is missing. |
| Current browser URL | Overlay app's local settings | Restore is configurable. |
| Browser cookies (including session cookies), site storage, and cache | `~/Library/Application Support/WoWIDEFeasibility/Chromium` (dedicated CEF profile) | Persist by default in the feasibility build. Menu action clears before CEF initializes on next launch. Never share Chrome or Brave profile directories. This ad-hoc-signed build uses CEF's mock keychain, so cookies are not meaningfully encrypted at rest. |
| Codex thread reference | Overlay app settings; conversation data remains with Codex | Restore the thread when Codex confirms it is available. Never log credentials. |
| In-flight Codex request | Codex runtime, queried by request/thread ID where supported | Do not replay automatically after restart. Show running/cancelled/unknown based on provider confirmation; never submit a duplicate silently. |
| Prompts and generated replies | Codex thread history; transient UI memory as needed | Follow Codex's configured history behavior. Exclude prompt and reply content from overlay diagnostics by default. |
| Authentication credentials | Codex's supported authentication/keychain flow | The overlay does not copy credentials into its own logs or ordinary settings. |

### Profiles

- Select a target app manually; process/window auto-detection is optional convenience.
- Store panel layout, opacity, and shortcuts by profile.
- Do not require parsing game files or identifying server internals.

## 10. Non-functional requirements

- macOS 14+ is a provisional floor; confirm against the user's machine before implementation.
- Native Apple Silicon support; decide Intel support at kickoff.
- Low idle CPU and memory use; overlay must not cause meaningful game frame-time degradation.
- Recover cleanly from game restart, overlay restart, display changes, and agent disconnection.
- Keep secrets out of logs and ordinary workspace files.
- Use OS-provided permission prompts; request Accessibility or other privileged access only if the chosen feature truly needs it.
- Support keyboard navigation and sufficient text contrast.
- Provide diagnostics that report overlay state without collecting game content by default.

## 11. Acceptance criteria for MVP

### P0 feasibility acceptance

1. On a recorded Forever build and Mac/display setup, an uncovered target area receives a click and a visible panel receives its click. Test panel center, edge, rounded corner, shadow, gap, and overlap cases.
2. In passive mode, new key presses during panel-button clicks, non-text content clicks, and custom-header dragging reach WoW, including while the pointer is moving. The overlay window becomes key only after an explicit text-field click. Return and a click outside the field restore new key input to WoW. Record app activation and focus at each step.
3. Hiding the overlay while WoW is frontmost works via a registered shortcut. If that cannot be demonstrated, do not promise the shortcut as the only recovery method; provide a working menu-bar command and document the shortcut limitation.
4. Repeat the test in the user's ordinary display mode and one fallback mode. Identify each as windowed, windowed-fullscreen/borderless, or macOS fullscreen Space. One passing mode does not imply support for another.
5. The test uses no game process modification, addon, memory access, or simulated game input.
6. Selecting a running target attaches the requested browser and terminal panels to its visible window without deliberately activating WoW IDE. When the target is not running, requested panels remain available for standalone debugging.
7. Manually hiding the panel prevents the app-activation watcher from immediately showing it again. Target termination resets that suppression for the next launch.

**P0 observation, 2026-09-23:** The user confirmed that new WoW keyboard input continues during custom-header dragging in windowed mode. Native title-bar dragging previously blocked new input. The rest of criterion 2 and the other display modes remain unverified.

### P1 release acceptance

8. Click-through and focus behavior pass on each configuration listed as supported in the published compatibility matrix. Other configurations are labeled untested or unsupported.
9. Overlay placement follows the selected target through move/resize/restart, or clearly switches to the documented manual-position fallback.
10. On restart, layout/profile selection restores. The feasibility browser opens a built-in start page, suggests its last HTTP(S) URL, and retains site data only in its dedicated CEF profile; a menu action clears it on the next launch. Agent thread references restore when supported by the provider; in-flight work is reported as running, cancelled, or unknown based on provider confirmation.
11. Codex displays the selected workspace and current sandbox/approval state. The read-only default and explicit approval path are verified; no action is silently approved.
12. Launching the overlay does not require modifying WoW, its addon folder, or its process. The overlay also works when manually positioned over a regular WoW window or ordinary app.

## 12. Risks and open decisions

- **Hit testing:** Separate panel-sized windows leave uncovered game space clickable. Test rounded corners, shadows, panel overlap, and exposed areas over the actual client. [Apple API](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents)
- **Focus and non-activating input:** AppKit provides non-activating panels and conditional key-window behavior, but CEF's nested native view may affect focus. Test native and CEF controls separately with WoW; text entry temporarily owns keyboard focus. [Apple NSPanel key behavior](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded)
- **Fullscreen Spaces:** AppKit can place auxiliary windows in a fullscreen Space, but visibility, stacking, mouse routing, and focus together remain unproven over Forever. Validate windowed, windowed-fullscreen/borderless, and macOS fullscreen as distinct cases. [Apple fullscreen auxiliary behavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary)
- **Emergency shortcut:** a global shortcut may conflict with game bindings or require permission depending on implementation. Test registration while WoW is focused and retain a menu-bar recovery route.
- **CEF packaging and rendering:** CEF brings helper processes, a large app bundle, and potential OS-version-specific focus and rendering behavior. Keep rendering and window-follow diagnostics separate so failures can be isolated. [CEF general usage](https://chromiumembedded.github.io/cef/general_usage)
- **Agent API and licensing:** Codex App Server is the first integration candidate. Confirm its current documented authentication, streaming, cancellation, and approval behavior before implementation; keep authentication and sandbox policy with Codex where possible.
- **Reference product status:** Astrum is relevant product inspiration for WoW-oriented workflow, but current public product material does not establish that its implementation is open source. Do not copy its code absent an explicit compatible license.
- **Open-source reuse:** a repository being public is not sufficient permission to copy it. Verify the exact license and preserve required notices.

## 13. Success measures

- User can play for a session with one agent panel and one reference panel available without frequent app switching.
- No repeatable blocked game click outside panel bounds.
- No persistent focus trap; the emergency hide path is reliable.
- No meaningful performance regression attributable to the overlay during representative gameplay.
- New provider panel can be added through the provider interface without changing core window/input code.

## 14. Decisions and validation still required

1. Record the user's actual WoW Forever display mode and exact client build for the first prototype run. The initial compatibility target is that real setup; alternate modes are tested separately.
2. Verify the overlay hit-testing model, panel focus, CEF page focus, fullscreen/Spaces behavior, and hide recovery on that setup before declaring the implementation ready.
3. Minimum macOS version and Intel support remain release decisions. The first feasibility run uses the recorded macOS 26.6 Apple Silicon environment above; this does not establish a product minimum.
4. Codex App Server is the initial agent target. Confirm supported authentication, streaming, cancellation, and approval flow before locking the provider protocol.
5. Decide whether panels follow a specific game window or default to manual display positioning after the target-tracking spike.
6. Decide distribution channel, signing/notarization, and project license before public release.

## 15. Research references

- [Apple `NSWindow.ignoresMouseEvents`](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents): window-level mouse transparency; selective panel hit testing still needs an explicit design.
- [Apple `NSPanel.becomesKeyOnlyIfNeeded`](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded): conditional key-window behavior, not proof of simultaneous game and panel text focus.
- [Apple `fullScreenAuxiliary`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary): an auxiliary window may appear in a fullscreen Space; actual game-overlay compatibility remains a prototype gate.
- [Blizzard Forever beta client update, 2026-09-22](https://us.forums.blizzard.com/en/wow/t/beta-client-update-september-22/2358655): build 69977 includes Mac display and stability fixes; the note does not establish third-party overlay behavior.
- [Codex App Server overview](https://openai.com/index/unlocking-the-codex-harness/): documented integration surface for custom Codex clients; version-specific behavior is to be confirmed during the provider spike.
