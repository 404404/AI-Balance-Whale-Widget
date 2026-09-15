# macOS capability matrix

This table records the fork boundary against the upstream DSH widget. It is
kept explicit so the local app does not present unsupported DSH actions as if
they were available.

| Upstream entry | Mac entry | Data source | Status / evidence |
| --- | --- | --- | --- |
| Whale role image and click animation | Local `WKWebView` whale widget | Bundled `assets/DSniang1.png`, local HTML | Implemented; image is also the AppIcon source; drag uses cumulative screen deltas and cancel handling. |
| Bubble display and refresh action | Local bubble above the whale | `ProviderState` bridge, no DSH route | Implemented; outer page has no scrollbar, hidden bubble is removed from hit testing. |
| DSH balance / ledger routes | No equivalent local route | N/A | Not ported; no fake balance is shown. |
| Upstream custom vendor templates and HTTP balance calls | No equivalent local provider UI | N/A | Not ported in this release; these actions are not exposed in the Mac menu. |
| Codex account and rate-limit windows | Native `CodexAppServerClient` | User-owned `codex app-server` over stdio | Implemented and verified with a real local CLI session; only `account/read` and `account/rateLimits/read` are used. |
| Upstream role / bubble / audio resource managers | Bundled runtime resources only | Application bundle resources | Runtime assets are copied and validated; editors/importers remain unported. |
| DSH task-end event accounting | No event source | N/A | Explicitly unavailable; the Mac app never turns missing events into zero usage. |
| DSH credential service | No WebView credential bridge | Codex CLI / CODEX_HOME owned by the user | Codex auth remains outside the app; tokens and `auth.json` are not passed to WebView or logs. |
