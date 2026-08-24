# ADR-0042: Experimental Web Conversation Viewport

Cuplivo will offer an opt-in Web conversation viewport for one-to-one chats on
Android, iOS, macOS, and Windows. Flutter continues to own the application
shell, composer, persistence, generation, tools, and every domain action. The
Web surface owns only DOM presentation, local interaction, and viewport scroll.

## Decision

Dart sends a versioned, renderer-neutral domain snapshot and ordered patches.
Every render session has a conversation id, revision, action epoch, request id,
and private capability token. Dart rejects duplicate or stale actions before
calling existing controllers. Large payloads are UTF-8 chunked; streaming
updates are coalesced per animation frame and patch only affected messages.

Browser assets and reviewed Markdown dependencies are committed locally. The
shell has a deny-by-default CSP, sanitizes generated HTML, denies native
permissions and navigation, and delegates external links to Dart. Scripted HTML
previews run only in sandboxed, network-denied iframes. A failed rich-content
block is isolated; shell, runtime, resource, and protocol failures use a
Flutter-hosted error surface with retry, content-free diagnostics, and a
conversation-scoped Flutter fallback.

The setting is device-local, defaults off, and is absent on Linux and Flutter
Web. Group chat and MultiAI remain Flutter-rendered. The same 360-message window
and 20-message pagination contract applies to both renderers.

## Alternatives rejected

- Sharing Flutter's visual-block projection: it would make the Web renderer a
  brittle serialization of widgets instead of an independent presentation.
- CDN assets or a Node build chain: both weaken offline reproducibility and the
  auditable security boundary.
- Replacing Flutter rendering outright: an experimental renderer needs an
  immediate, explicit fallback while behavior and platform runtimes mature.
- Giving JavaScript persistence or tool authority: this duplicates domain
  state and creates an unsafe native capability boundary.

## Consequences

Two renderers must remain behaviorally aligned. Browser rasterization may differ
slightly, but action semantics, domain state, localization, themes, and message
ordering remain Dart-authoritative. Future styling and print work may target
stable DOM component markers without introducing custom scripts in v1.
