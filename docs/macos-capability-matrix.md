# macOS capability matrix

This matrix describes the implemented local AppKit/WKWebView boundary. The legacy
DSH plugin remains a separate npm package and keeps its upstream attribution.

| Upstream capability | macOS entry | Status |
| --- | --- | --- |
| Whale role, click/press animation, drag, snap and flip | Local transparent WKWebView plus native NSPanel layout model | Implemented; old 248x274 frames migrate to a measured layout and bottom whale anchor. |
| Bubble display and custom click menu | Standalone mount reusing upstream .dshwv-pop SVG, bshape/b1/b2 and staged animation | Implemented; immediate offline-safe click, compact measured layout, custom menu and no outer scrollbar. |
| Codex account and rate-limit windows | Native stdio codex app-server plus WHAM HTTP fallback and settings locator | Implemented for the installed Codex login: account/read, account/rateLimits/read and rateLimits/updated are preferred; the read-only WHAM fallback handles primary/secondary/additional windows. Browser login delegates to the installed official `codex login` command, so the App never receives or displays auth material. |
| Vendor balance/quota templates and HTTP fields | Native URLSession adapter and Keychain references | Implemented for configured endpoints; no-balance vendors are explicitly unavailable and never show fabricated values. |
| General / desktop settings | One key/resizable local Settings.html window | Implemented; scale, snap, position reset, topmost, Spaces, login item and passthrough share one source of truth. |
| Role and image manager | Application Support resource store | Implemented; built-in previews, import, use, delete and role persistence. |
| Bubble content editor | Direct upstream editor mounted inside the “气泡与内容” page | Implemented without an iframe; the upstream SVG bubble, staged animation, queue/choice editor, module layout/style controls, random presets, library, preview and native route adapter share the desktop configuration path. |
| Audio settings | Direct upstream audio-group/resource panels plus App controls | Implemented; built-in/imported groups, press/release slots, preview and crop management are reachable from the unified settings page and persist without restarting app-server. |
| Reminders and usage records | Direct upstream usage editor plus local source-labelled records | Implemented for configuration and available local data; official Codex quota is not converted into a fake token ledger, and the App reports when no session event source is connected. |
| DSH routes and browser host | None | Not used by the Mac App; it runs without DSH, Node.js or a browser. |
| Developer ID signing/notarization | GitHub Actions signing mode | Ad-hoc is supported when secrets are absent; Developer ID/notarization is conditional on repository secrets. |

## Beta 12 verification boundary

The beta.12 candidate mounts the upstream editor directly in the unified settings page, routes native input through `NSPanel.sendEvent`, preserves the canonical upstream bubble fixture, and carries a per-refresh request identity through the app-server/HTTP fallback. CI runs source fixtures, packaged WKWebView geometry/input/editor/login-bridge tests, non-empty JUnit output checks, arm64 bundle checks, DMG mount checks and ad-hoc codesign integrity checks. This Linux execution environment cannot run Finder, AppKit or a real Codex account; GUI/pointer/Spaces and real-account checks remain explicitly unverified until the uploaded DMG is run on macOS. CI fixtures never contain credentials.
