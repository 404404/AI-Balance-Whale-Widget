# macOS capability matrix

This matrix describes the implemented local AppKit/WKWebView boundary. The legacy
DSH plugin remains a separate npm package and keeps its upstream attribution.

| Upstream capability | macOS entry | Status |
| --- | --- | --- |
| Whale role, click/press animation, drag, snap and flip | Local transparent WKWebView plus native NSPanel layout model | Implemented; old 248x274 frames migrate to a measured layout and bottom whale anchor. |
| Bubble display and custom click menu | Standalone mount reusing upstream .dshwv-pop SVG, bshape/b1/b2 and staged animation | Implemented; immediate offline-safe click, compact measured layout, custom menu and no outer scrollbar. |
| Codex account and rate-limit windows | Native stdio codex app-server plus settings locator | Implemented; account/read, account/rateLimits/read and rateLimits/updated only; automatic executable, effective CODEX_HOME, config.toml/sessions status and CLI version are visible without exposing auth data. |
| Vendor balance/quota templates and HTTP fields | Native URLSession adapter and Keychain references | Implemented for configured endpoints; no-balance vendors are explicitly unavailable and never show fabricated values. |
| General / desktop settings | One key/resizable local Settings.html window | Implemented; scale, snap, position reset, topmost, Spaces, login item and passthrough share one source of truth. |
| Role and image manager | Application Support resource store | Implemented; built-in previews, import, use, delete and role persistence. |
| Bubble content editor | One persisted schema shared by Settings.html and the standalone widget renderer | Implemented; first/again actions, queue advance, text/link/image/GIF/dynamic/random modules, weights, no-immediate-repeat choice, order, color/size, module library, preview and restart persistence. |
| Audio settings | Built-in/imported audio references, volume and press/release selection | Implemented; selection is persisted and changes do not restart app-server; secrets are not involved. |
| Reminders and usage records | Threshold/budget preferences and source-labelled records | Implemented as configuration; official Codex quota is not converted into a fake local token ledger. A real session event source is not bundled. |
| DSH routes and browser host | None | Not used by the Mac App; it runs without DSH, Node.js or a browser. |
| Developer ID signing/notarization | GitHub Actions signing mode | Ad-hoc is supported when secrets are absent; Developer ID/notarization is conditional on repository secrets. |

## Beta 7 verification boundary

The beta.7 candidate adds the complete upstream `whale-widget.js` editor and a native local route adapter. CI runs Swift fixtures, packaged WKWebView geometry/resource tests, arm64 bundle checks, DMG mount checks and ad-hoc codesign integrity checks. This Linux execution environment cannot run Finder, AppKit or a real Codex account; GUI/pointer/Spaces and real-account checks remain explicitly unverified until a user runs the uploaded DMG on macOS. CI fixtures never contain credentials.
