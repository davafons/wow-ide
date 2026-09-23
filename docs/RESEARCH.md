# Research and Compatibility Notes

**Last checked:** 2026-09-23  
**Scope:** Mac overlays, WoW/Forever fit, reuse candidates, agent/browser building blocks.

**Test machine baseline:** macOS 26.6 (25G72), Apple M2 Pro, 5K/144 Hz + 4K/60 Hz displays. Blizzard's September 22 beta update identifies WoW Forever 1.60.1 Build 69977 and includes Mac display/stability fixes. This is a candidate test target only; overlay compatibility has not been demonstrated. [Blizzard beta update](https://us.forums.blizzard.com/en/wow/t/beta-client-update-september-22/2358655)

## Findings

### Existing products and projects

| Candidate | What it appears to offer | Fit for this project |
|---|---|---|
| Astrum | Advertises a native Mac overlay for WoW with global chat; its download page lists macOS Sonoma 14+ and Intel/Apple Silicon. | Best WoW-oriented UX/product reference to try. Its public material reviewed here does not establish an open-source license or arbitrary app panels, so treat as product inspiration, not code donor. https://www.astrum.gg/download |
| Peekaboo | Mac transparent, always-on-top web window, click-through/hover reveal, hide shortcut; repository says implemented and links an MIT license. | Closest open-source implementation reference for Mac window behavior. It is a single browser overlay, not the requested agent workspace. Audit code, project health, build requirements, and exact license before forking/copying. https://github.com/JakeB-5/peekaboo |
| Interceptor | Mac overlay documentation shows WKWebView in NSPanel and click-through/noninteractive modes. | Useful implementation notes, but repo is under Elastic License 2.0, not an MIT-style permissive license. Reference only unless licensing is deliberately approved. https://github.com/Hacker-Valley-Media/Interceptor |
| Hudkit | HTML/WebKit desktop HUD with explicit clickable rectangles. | Not viable as a Mac donor: project page lists Linux support and explicitly marks OS X unsupported. ISC license, but wrong platform. https://github.com/anko/hudkit |
| Astrum vs open-source | Astrum's site offers a WoW Mac overlay, but this review found no public source repository/license. | Try the product to learn its activation, footprint, and WoW behavior; do not assume source can be reused. |
| Overwolf | Its support page says macOS is unsupported. | Exclude for Mac-first implementation. https://support.overwolf.com/support/solutions/articles/9000177155-general-issues-and-solutions |

These findings do not prove that no other project exists. They show that the reviewed candidates do not clearly deliver the full combination: open-source, Mac-native, WoW-aware as an optional profile, panel-specific input, browser, and multiple agent integrations.

### Platform building blocks

- AppKit exposes window transparency, window levels, collection behavior, and `ignoresMouseEvents`; window and app activation behavior still needs a real prototype. https://developer.apple.com/documentation/appkit/nswindow
- `ignoresMouseEvents` is a window-level property. The core requirement for spatial pass-through therefore needs a tested input-window design (for example, a click-through canvas with separately interactive panel windows) rather than an assumption that transparent pixels pass through. https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents
- AppKit supports auxiliary windows in fullscreen Spaces, and `NSPanel` supports conditional key-window behavior. These APIs do not establish reliable combination with Forever's renderer, game mode, and desired focus model; test those combinations in-client. https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded
- `WKWebView` is Apple's native embedded web-content view and is a plausible browser/HTML panel. https://developer.apple.com/documentation/webkit/wkwebview
- macOS Spaces and fullscreen compatibility involve window collection behaviors. Verify the desired panel configuration against WoW Forever beta rather than assuming ordinary topmost-window behavior covers every game mode. https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct
- Codex App Server is a documented long-lived JSON-RPC integration surface for building a custom Codex client. https://openai.com/index/unlocking-the-codex-harness/

### WoW Forever compatibility stance

Treat the Forever beta client as an external target window, not as a platform-specific overlay runtime. This reduces dependence on addon version/API compatibility and makes the shell reusable over regular WoW and ordinary apps. Game-specific context sharing (for example an addon-to-local companion bridge) is a separate optional project and is out of the initial overlay MVP.

Before implementation, record the exact Forever beta client/build, Mac model/CPU, macOS version, game display mode, resolution, and display arrangement. Window stacking/input behavior is sensitive to this environment.

## Reuse recommendation

1. First, prototype AppKit input routing in a minimal new app against the actual beta client.
2. In parallel during implementation, audit Peekaboo's MIT-licensed source for reusable window/hotkey patterns. Prefer extracting/adapting only narrow components with preserved copyright/license notices rather than taking on an unrelated product wholesale.
3. Test Astrum as a product reference if available to the user; note its UI, show/hide gesture, game-mode compatibility, and focus behavior.
4. Do not reuse Interceptor code unless the project explicitly chooses to accept Elastic License 2.0 terms after review.

## Questions still open

- Exact WoW Forever beta build and in-game display mode for each compatibility run.
- Which display modes will be published as supported after testing.
- Apple Silicon vs Intel support required for public release.
- Codex App Server is the first integration candidate; confirm the selected Codex version's authentication, streaming, cancellation, and approval behavior during the provider spike.
- Whether the overlay should follow the WoW window or be manually anchored on the display.

## Source links

- Astrum download: https://www.astrum.gg/download
- Peekaboo: https://github.com/JakeB-5/peekaboo
- Interceptor overlay docs: https://github.com/Hacker-Valley-Media/Interceptor/blob/main/docs/native/overlays.md
- Interceptor license: https://github.com/Hacker-Valley-Media/Interceptor/blob/main/LICENSE
- Hudkit: https://github.com/anko/hudkit
- Overwolf compatibility: https://support.overwolf.com/support/solutions/articles/9000177155-general-issues-and-solutions
- AppKit NSWindow: https://developer.apple.com/documentation/appkit/nswindow
- WKWebView: https://developer.apple.com/documentation/webkit/wkwebview
- Codex App Server: https://openai.com/index/unlocking-the-codex-harness/
