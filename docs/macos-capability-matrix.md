# macOS capability matrix

This matrix describes the implemented local AppKit/WKWebView boundary. The legacy
DSH plugin remains a separate npm package and keeps its upstream attribution.

| Upstream capability | macOS entry | Status |
| --- | --- | --- |
| Whale role, click/press animation, drag, snap and flip | Local transparent WKWebView plus native NSPanel layout model | Implemented; old 248x274 frames migrate to the current computed content size. |
| Bubble display and custom click menu | Local HTML bubble and custom context menu | Implemented; click opens immediately even when Codex is offline; no outer scrollbar. |
| Codex account and rate-limit windows | Native stdio codex app-server | Implemented; account/read, account/rateLimits/read and rateLimits/updated only. |
| Vendor balance/quota templates and HTTP fields | Native URLSession adapter and Keychain references | Implemented for configured endpoints; no-balance vendors are explicitly unavailable and never show fabricated values. |
| General / desktop settings | One key/resizable local Settings.html window | Implemented; scale, snap, position reset, topmost, Spaces, login item and passthrough share one source of truth. |
| Role and image manager | Application Support resource store | Implemented; built-in previews, import, use, delete and role persistence. |
| Bubble content editor | Persisted text/link/image/status step list | Implemented; edits preview in the widget and remain after restart. |
| Audio settings | Built-in/imported audio references, volume and press/release selection | Implemented; secrets are not involved. |
| Reminders and usage records | Threshold/budget preferences and source-labelled records | Implemented as configuration; official Codex quota is not converted into a fake local token ledger. A real session event source is not bundled. |
| DSH routes and browser host | None | Not used by the Mac App; it runs without DSH, Node.js or a browser. |
| Developer ID signing/notarization | GitHub Actions signing mode | Ad-hoc is supported when secrets are absent; Developer ID/notarization is conditional on repository secrets. |
