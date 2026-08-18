# ADR-0037: Android SAF external-directory mounts via mirror sync

Issue #316 asked for a way to "mount" a user-picked Android directory into the Linux workspace so the AI can read and write it directly. Android's Storage Access Framework (SAF) is the sanctioned way to access user-selected directories — but SAF hands out `content://` tree URIs that carry **no host file path**, which collides with three hard facts of this codebase: the filesystem engine (`KelivoFilesystemMcpServerEngine`) does plain `dart:io` IO on host paths (76+ touch points), proot bindings (`-b host:guest`) need a real host directory, and the model-facing vocabulary is `/workspace/...` only.

Decision: **mirror sync, not a content-URI IO layer.** The user picks a directory via `ACTION_OPEN_DOCUMENT_TREE` with a persisted read/write grant; the app mirrors it into an app-private host directory (`<appData>/saf_mounts/<alias>`); the engine, the model tools and the proot guest all see the mirror; a sync service keeps the two sides in two-way mirror sync.

## Hard constraints that shaped the design

1. **content:// URIs are not host paths.** The engine's 76+ `File`/`Directory` touch points cannot be retargeted at URIs without a full `FsAccessor` abstraction layer — a large refactor with high regression risk across every tool path, the trash markers, the fetch cache and the download service. A mirror keeps the engine completely unchanged: `mount.path` is a real host path.
2. **proot binds host paths.** The Linux guest (`/workspace` = bound workspace) can see SAF content only through a real host directory. The mirror is bound as `/workspace/.mounts/<alias>` (`-b <mirror>:/workspace/.mounts/<alias>`), matching the existing dotdir convention (`.sandbox`, `.fetch_cache`).
3. **External mounts never sync.** Desktop external mounts (`filesystem_mounts_v1`) established the rule: mount content never enters backups or LAN sync, and the sync-scope overlap validation rejects any mount inside a sync tree. The mirror therefore lives at `<appData>/saf_mounts/` — app-private, outside the sync roots (`upload/images/avatars/fonts/skills/workspaces`). Its config (`saf_mounts_v1`) rides `settings.json` like the desktop mount config, loaded only on Android; restored-elsewhere URIs are invalid → `unavailable` until re-authorization.
4. **SAF can't notify on external changes.** There is no FileObserver for content URIs. Change discovery is polling: initial pull on mount, a debounced push after AI writes, one round on app resume, a 60 s foreground poll, and a manual "sync now".

## Sync semantics

- **Three-state merge by mtime+size**, last-writer-wins; mtime ties resolve to the mirror side (deterministic, avoids a provider-vs-mirror ping-pong on equal timestamps).
- **Deletion propagation, both ways, gated by a snapshot.** `.state/<alias>.json` records every path seen at the last *completed* round; only a path present in the snapshot whose single side is gone counts as a deletion (user deleted in the file manager → mirror entry removed; AI deleted in the mirror → SAF entry deleted). Brand-new files are never treated as deletions.
- **Whole-tree-gone guard.** If the SAF side lists empty while the snapshot knew content, the round aborts instead of propagating deletions (unmounted SD card / revoked grant case) — regardless of mirror state, because mirror files in that state may hold AI edits never pushed. Nothing real is lost: files re-pull after remount, and a genuinely emptied folder can be re-mounted to start fresh.
- **Unavailable semantics.** A failed `checkAccess` or a `SecurityException` during the walk marks the mount `unavailable`: nothing is pushed, nothing is deleted, local mirror changes are preserved, and recovery is automatic on the next trigger.
- **No ping-pong pulls.** After pushing a mirror file, the SAF entry is re-statted and the mirror mtime is aligned to the post-write SAF mtime, so the next round sees "same" instead of re-copying.
- **AI write triggers.** The engine gained an advisory `onMountMutated(alias)` callback (write/patch/mkdir/delete/move/zip/unzip/download) that schedules a 500 ms debounced push — no engine IO change, just a notification seam.

## Model-facing vocabulary

The model addresses SAF mounts as `/workspace/.mounts/<alias>/rel` (parse + present translation in `workspace_path_presentation.dart`), consistent with the guest bind and with the strict `/workspace`-only input rule. `.mounts` is a reserved dotdir: a literal workspace folder named `.mounts` is shadowed (same convention as `.sandbox`). Unknown aliases are rejected at parse time. The mount listing (`read('/')`) presents `/workspace/.mounts/<alias> (ro|rw)` via the existing presenter.

## Guardrails

- **Alias validation** reuses `isValidMountAlias`; `workspaces`/`default` and every workspace alias are reserved (collision with a workspace alias would make two mounts resolve the same wire alias).
- **`kelivo_fetch` rejects SAF mounts** as download targets: the download and its `.fetch_cache` continuation cache live inside the mount and would be mirrored back into the user's real folder.
- **Deletion markers never fire for SAF mounts** (`_isSyncedWorkspaceMount` matches only `default`/`workspaces`/`workspace_N`), so SAF deletions never enter the trash/marker protocol — they propagate directly to the source directory.
- **ro mounts**: `readOnly` is selectable at add time (default rw, per the issue); the engine enforces ro for tools and the proot bind appends `:ro`.
- **`clearAllData`** wipes `<appData>/saf_mounts/` (mirrors + snapshots); the config rides the settings wipe.

## Considered options

1. **Mirror sync (chosen).** Zero engine IO changes, works on SD cards / USB OTG / any DocumentsProvider, guest-visible via proot, reuses the whole mount infrastructure. Costs: two-way sync semantics (latency, conflict rule), a snapshot file, and external edits are only visible on the next poll round.
2. **ContentResolver bridge + engine `FsAccessor` abstraction.** "True" direct access, but a 76-site refactor of the engine with high regression risk; the proot guest still cannot see the directory (no host path), so the issue's "mount into the Linux workspace" would be only half-satisfied. Deferred as a possible future fast-path.
3. **`MANAGE_EXTERNAL_STORAGE` all-files access.** SAF-picked dirs on primary storage could resolve to real paths and mount directly, but the permission is policy-risky for distribution, covers only primary storage (no SD/OTG), and requires a user-facing settings toggle — rejected.

## Consequences

- Android-only feature; desktop/iOS never load `saf_mounts_v1` (config persists in prefs, never mounted — same pattern as desktop mount configs on mobile).
- New native plugin `cuplivo/saf_mount` (SafMountPlugin.kt: pickTree with persistable grant, list, readFile, writeFile via `openDescriptor("rwt")`, createFile, mkdir, delete, checkAccess) + `androidx.documentfile:documentfile:1.0.1`.
- Storage UI gains an Android-only SAF mounts section (add / status / sync now / remove) in the storage page.
- The sandbox channel `exec`/`ptyLaunchSpec` accept an optional `binds` payload; `buildGuestCommand` emits `-b <mirror>:/workspace/.mounts/<alias>[:ro]`.
- Cross-device restore: persisted tree URIs are device-scoped; the mount surfaces as `unavailable` with a re-authorize hint; the mirror is re-pulled after re-adding.
