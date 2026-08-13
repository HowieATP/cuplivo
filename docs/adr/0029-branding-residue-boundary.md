# ADR-0029: Branding Residue Boundary (Kelivo names kept by design)

**Status:** Accepted (2026-08-11)

## Context

Issue #274 ("希望夺舍完全") asked for every remaining `Kelivo` reference to be replaced with `Cuplivo`. A full audit found the residue splits into two fundamentally different kinds: user-visible / third-party-visible brand strings (notifications, about page, share text, HTTP User-Agent, OpenRouter title, MCP client name, downloaded file prefixes), and **identity-bearing surfaces** where the Kelivo name is part of the data or protocol and renaming it breaks existing behavior.

## Decision

Tier-A sweep only (issue #274):

- **Renamed to Cuplivo**: notification strings, about-page app title, share text, Android background-notification fallback, `cuplivo-table-*` / `cuplivo-mermaid-*` / `cuplivo_tts_*` file prefixes, HTTP `User-Agent`, OpenRouter `X-OpenRouter-Title` + `HTTP-Referer` (both aligned with ADR-0003's original intent, which the code had never followed), and MCP client names (`Cuplivo MCP` / `Cuplivo App`).
- **Kept as Kelivo by design** (see CONTEXT.md "Branding & Naming Boundary"):
  - `kelivo_*` MCP tool names and `@kelivo/*` server ids — model-facing protocol, persisted in `assistant.mcpServerIds`, recorded in tool events and conversation history; renaming breaks recorded calls and forces models to relearn tool names with zero user-visible branding benefit
  - `KelivoIN` provider key — persisted provider config with special-cased defaults; label and key are one string. **Superseded (2026-08):** removed from the built-in provider set and its special-cased defaults deleted; pre-existing persisted configs remain as ordinary user data.
  - `assets/icons/kelivo.png` + the `kelivo` brand regex — legacy provider icon references
  - `/kelivo/` path matching in `SandboxPathResolver` — resolves legacy Windows AppData paths in old messages/backups
  - `kelivo.psycheas.top` / `afdian.com/a/kelivo` / `kelivo-helper.netlify.app` URLs — external infrastructure Cuplivo does not control (ADR-0003 already decided these stay)
  - `KelivoImageSettingsMapper` and the "Kelivo backup" interop terms — they describe the upstream project, which legitimately exists (ADR-0028)
  - Internal code identifiers (`KelivoFilesystemMcpServerEngine`, `kelivo_filesystem/` directory, iOS `KelivoGenerationActivityAttributes.swift` filename) and README/CHANGELOG upstream references (AGENTS.md 1.4) — deferred to a separate mechanical follow-up, not part of this sweep

## Considered Options

| Option | Rejected Because |
|--------|------------------|
| Rename everything including protocol names, with migration | Breaking the model-facing tool namespace and recorded history for zero user-visible gain; old tool events and prompts would reference dead tool names |
| Rename only the About page and notifications | Would leave the outbound HTTP identity (User-Agent, OpenRouter, MCP handshake) still claiming "Kelivo" to every third party the app talks to |

## Consequences

- Third parties (API providers, OpenRouter, external MCP servers, log readers) now see a consistent Cuplivo identity; OpenRouter analytics attribution for the original project resets (risk already accepted in ADR-0003).
- A future v4.0 can still rename the protocol surfaces — the boundary is documented in CONTEXT.md, so the cost and scope of that decision are visible.
- Tests asserting the old strings (e.g. `request_logger_redact_test.dart` User-Agent) were updated in the same change.
