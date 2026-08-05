# Linux Sandbox v2: real runtimes, layout, and explicit base env

Supersedes the Android-stub / single-flat-root parts of ADR-0020. Tool names,
approval defaults, path jail rules, and **metadata-only backup** remain.

## Decision

Each sandbox owns a tree under app data:

```
{appData}/linux_sandboxes/<id>/{files,linux,tmp}/
```

- `files/` — user workspace; path-jailed file tools and local shell cwd.
- `linux/` — per-sandbox rootfs / runtime payload (WSL, native, PRoot).
- `tmp/` — install and runtime scratch.

**v1 migrate:** a flat `linux_sandboxes/<id>/` tree (no `files/` child) moves
non-reserved entries into `files/` on `ensureLayout`.

`ensureReady` is **layout only** (create dirs + migrate). It does not download
or mark the sandbox ready for tools.

`installBaseEnv` is **explicit** (UI / provider). Local modes (Windows
`localJail`, native Linux without a full rootfs pack) may only layout + write a
base-env marker and set `status=ready`. Heavier modes (WSL, Android PRoot)
override install.

### Platform runtime modes

| Mode | Platform | Notes |
| --- | --- | --- |
| `localJail` | Windows fallback | Host folder jail only — **not Linux**. Honest in tool copy. |
| `wsl` | Windows preferred | Real Linux via WSL when available (Phase B). |
| `nativeLinux` | Linux desktop | Shell via `/bin/sh -c`, cwd=`files/`. |
| `proot` | Android | Convenience isolation, **not a security boundary**; network remains unrestricted residual risk (Phase C). |
| `unsupported` | iOS/macOS/etc. | Tools refused. |

### Status machine

`disabled` | `notReady` | `installing` | `ready` | `broken`

- Tools (defs + exec) require `status == ready`.
- Load integrity: persisted `installing` → `broken` (crashed mid-install).
- Unknown status string in JSON → `broken` (never silent-ready).
- New sandboxes start `notReady`; create UI may call `installBaseEnv` when base env is checked.

### Backup

Unchanged from v1: prefs / `settings.json` metadata only. Disk under
`linux_sandboxes/` is never included in backup/restore.

### Factory

`createSandboxRuntime(id)` selects Windows (WSL preferred / local jail
fallback), native Linux, Android PRoot, or unsupported.

### Android PRoot (Phase C)

Hybrid install path:

- Dart: download Ubuntu base tarball (DioHttpClient), extract with
  `package:archive` into per-sandbox `linux/`, patch DNS/hosts/tmp, write
  base-env marker.
- Kotlin (`app.linux_sandbox`): ABI/native lib dir + `execShell` via
  `libproot_exec.so` binding `files/` → `/workspace`.

`ensureReady` remains layout-only. Shell requires ready rootfs (`linux/bin/sh`
+ marker). PRoot is convenience isolation, not a security boundary.

## Consequences

- Windows local jail remains usable but is labeled as a folder jail, not Linux.
- Android UI may exist earlier than a security claim; copy must not oversell.
- Provider owns status persistence; runtimes own layout, probe, and install.
