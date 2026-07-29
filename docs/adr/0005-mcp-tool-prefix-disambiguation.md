# MCP Tool Name Disambiguation via Per-Server Prefix

When multiple MCP servers (or an MCP server and a built-in tool) expose tools with the same `function.name`, the LLM API rejects the entire request as a duplicate-name error. We resolve this with a user-configured per-server prefix (`{prefix}_{originalName}`), enforced by a hard block at send time with a guidance dialog.

## Considered Options

- **Per-tool rename**: Rejected. MCP tools come in suites (e.g. `create_memory` / `edit_memory` / `delete_memory`); renaming one tool breaks the family pattern the LLM uses to infer relationships. Also, many server names are Chinese characters — invalid in OpenAI's `^[a-zA-Z0-9_-]{1,64}$` function name constraint, making auto-generated per-tool names unreliable.
- **Silent exclusion of the colliding MCP tool**: Rejected. Breaks suite integrity — the LLM sees a partial tool family and may call the built-in expecting MCP semantics.
- **Auto-prefix fallback (no user action)**: Rejected. Auto-generated slugs are opaque, and the user has no awareness or control of what the LLM sees.
- **Per-assistant-per-server prefix**: Rejected as over-engineering. Server-level prefix is simpler; the token cost of an unnecessary prefix on a non-colliding assistant is negligible.

## Consequences

- The prefix is global to the server (all assistants see prefixed names), even though collisions are per-assistant. Acceptable trade-off: one configuration point, negligible token overhead.
- Changing a prefix mid-conversation means historical tool-call records in the conversation use the old name. The LLM handles this gracefully (tool_call_id links results, not names), but the user may see inconsistent names when scrolling history.
- The send-time hard block is the only enforcement point. There is no early warning at server connection time — the user discovers collisions only when they first try to chat with a conflicting configuration.
