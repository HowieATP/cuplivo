# ADR-0039: Search Services Sync with Upstream (Providers, Multi-Key UI, Usage)

Cuplivo syncs the search-service layer from upstream Kelivo (issue #311):
four new providers (Doubao, Firecrawl, StepFun, TinyFish), the account-usage
card, and the full-page service editor with multi-key rotation management.
Upstream's implementation is built on a plain string model (`apiKey` +
`extraApiKeys: List<String>` + stateless `SearchApiKeyRotator`); Cuplivo has a
richer native model (`apiKeys: List<ApiKeyConfig>` + `KeyManagementConfig`)
that predates the sync. The sync therefore adapts upstream's UI and services to
Cuplivo's model rather than porting upstream's key plumbing verbatim.

## Decision

- **Provider scope**: port Doubao, Firecrawl, StepFun, TinyFish. Exclude
  upstream's `kelivo_search_service.dart` — a keyless built-in proxy to
  `search.psycheas.top` with a token baked into the binary. A fork silently
  routing user queries to the upstream author's private endpoint is a
  trust/supply-chain decision that must not be made by default.
- **Key model stays local**: upstream's `primary`/`extras` strings are a wire
  format only. Ported UI writes Cuplivo's `List<ApiKeyConfig>` (per-key
  enabled/priority/status/usage) + `KeyManagementConfig`. Upstream's
  round-robin rotator is not ported; `SearchToolService`'s existing rotation
  (4 strategies, failure-disable, auto-recovery, persisted `roundRobinIndex`)
  remains the runtime path.
- **UI architecture, platform-split**:
  - Mobile: upstream's full-page `SearchServiceEditorPage` (provider chips,
    config card, usage card, test card) pushed via `Navigator.push`, replacing
    the old bottom-sheet editor. The local rich per-key row UI (enable toggle,
    add/remove) survives inside the editor's multi-key section; batch paste
    (`SearchApiKeysPage`) feeds the `ApiKeyConfig` list as a convenience.
  - Desktop: the nav-rail `DesktopSearchServicesPane` keeps its dialog-based
    editor (no route stack), gains the four providers and batch-paste entry in
    its key management section.
- **Account usage semantics**: `SearchServiceUsageService` queries only the
  primary key (first enabled — `SearchServiceOptions.apiKey` getter), matching
  upstream's per-primary-key behavior. It never touches the rotation cursor
  (usage polling must not perturb search distribution). On-demand fetch, no
  persistence, 10s timeout, 2 retries. Tavily `/usage` and LinkUp
  `/credits/balance` only.
- **Shared usage cache**: a static in-memory cache (keyed by service id +
  provider + credential + endpoint, capped at 50 entries, full clear on
  overflow) lives in `SearchServiceUsageService` and is shared by the mobile
  editor page and the desktop edit dialog, so a query on either surface is
  instantly visible on the other. Desktop deviation from upstream: the edit
  dialog shows a compact usage panel (auto-query when a credential exists,
  manual refresh) because upstream has no desktop usage UI.
- **Firecrawl is key-optional**: hosted `/v2/search` accepts keyless requests;
  the key field is shown but not required, and no `Authorization` header is
  sent when empty. Matches upstream commit `2257ac13`.
- **Backup compatibility contract (hard constraint)**: the four new providers
  ride the existing dual-write path — `toJson()` via `writeKeys` (full
  `keyConfigs` objects + string `apiKeys` pool + primary `apiKey`), `fromJson()`
  via `readKeys` (3-tier read), `type` strings exactly matching upstream
  (`doubao`, `firecrawl`, `stepfun`, `tinyfish`), and `prepareBackupFile`'s
  export split untouched. Both directions round-trip: Cuplivo→Kelivo restore
  and Kelivo→Cuplivo restore.

## Considered Options

1. **Verbatim port of upstream's string model** (`apiKey` + `extraApiKeys` +
   `SearchApiKeyRotator`): rejected — Cuplivo's richer `ApiKeyConfig` model is
   already persisted and round-trips through backup; downgrading to strings
   would orphan `SearchToolService`'s failure-disable/recovery logic and lose
   per-key status in the UI.
2. **Port upstream's rotator alongside the local one**: rejected — two
   rotation mechanisms with divergent persistence would be dual truth.
3. **Include the Kelivo built-in proxy**: rejected — see Decision (trust
   boundary).
4. **Replace the desktop dialog editor with the mobile editor page**: rejected
   — desktop uses nav-rail panes, not a Navigator route stack (AGENTS.md 3.10).
5. **Usage-per-key polling in the keys page**: rejected — upstream
   deliberately avoids hammering usage endpoints per key (HTTP 429 risk);
   the keys page shows the pool, the editor card shows primary-key usage.

## Consequences

- Users get four new providers with full parity to upstream, plus the usage
  card and multi-key management on both platforms.
- Upstream's `primary`/`extras` backups restore into Cuplivo's rich model
  (string pool → `ApiKeyConfig`); Cuplivo exports remain readable by Kelivo's
  business router (`apiKeys` stays a plain string list).
- Auto-disabled keys (runtime failure handling) remain re-enableable in the UI
  via the per-key toggle — a capability upstream's string-only UI lacks.
- The Kelivo proxy is intentionally absent; if it is ever wanted, it requires
  an explicit decision about the hardcoded endpoint/token.
- `desiredFileName.txt` stays empty (all new ARB keys translated in 4 files).
