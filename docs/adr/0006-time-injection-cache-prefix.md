# Time injection at message tail to preserve cache prefix

LLM providers (Anthropic, OpenAI, etc.) cache the longest stable prefix of the message array. Putting timestamps in the system prompt or using volatile template variables (`{{ time }}`, `{cur_date}`) invalidates the entire prefix on every request. We inject a per-message timestamp (`\n\n(Mon 25-07-26 14:03:22)`) derived from the immutable `ChatMessage.timestamp` at the tail of each user message instead. Historical messages produce byte-identical output across requests on a device with a stable timezone (the timestamp uses device-local time without a UTC offset), so the prefix remains cacheable. Only the new trailing user message differs — which is expected since it carries new content anyway.

## Considered Options

- **System prompt injection** (`{cur_datetime}` in system message): invalidates the entire cache prefix every request. Rejected.
- **Message template with `{{ time }}`**: uses `DateTime.now()` at send time, volatile for the last message, and only applies to the last user message (historical messages get no time context). Rejected.
- **Tail injection from stored timestamp** (chosen): deterministic, cache-stable, applies uniformly to all user messages, trivially reproducible on regeneration/retry.

## Consequences

- The message template is bypassed entirely when time injection is enabled. Users who rely on non-time template features (e.g. XML wrapping) must choose one or the other. Accepted: the feature is opt-in and defaults to off.
- Toggling the feature on/off changes the system message (adds/removes `<time-note>`), causing a one-time cache invalidation. Accepted as unavoidable.

## Sync note (issue #308, 2026-08)

Upstream (Kelivo, memory-v2 refactor) renamed the toggle to `appendCurrentTimeToUserMessage`, dropped the `<time-note>` system note, switched to a `<current_time>` tail tag, and allowed the message template to coexist. Cuplivo explicitly keeps the original runtime design: tail `(Mon …)` format, `<time-note>`, template bypass. Wire compatibility is provided ONLY at the model JSON boundary (`Assistant.toJson` dual-writes both keys, `fromJson` reads new-key-first with a legacy fallback) so old ZIPs restore on new builds and vice versa. No field rename, no DB migration.
