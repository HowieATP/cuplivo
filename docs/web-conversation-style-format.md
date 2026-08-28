# Web Conversation Style Format

Cuplivo Web conversation styles are declarative JSON files. A filename must
end in `.cuplivo-style.json`. See the directly importable
[`soft-cards` example](examples/soft-cards.cuplivo-style.json).

```json
{
  "kind": "cuplivo.web-conversation-style",
  "schemaVersion": 1,
  "id": "soft-cards",
  "name": "Soft Cards",
  "description": "Optional description",
  "common": {
    "userBubble": {},
    "assistantBubble": {},
    "processCard": {}
  },
  "light": {},
  "dark": {}
}
```

`kind`, `schemaVersion`, `id`, and `name` are required. `description` is
optional. `id` uses lowercase ASCII letters, digits, and single hyphens, with
no leading or trailing hyphen; it is at most 64 characters. `name` is at most
80 characters and `description` at most 240.

## Layers and surfaces

Cuplivo first applies the current app theme and existing display settings,
then `common`, then the active `light` or `dark` layer. Missing fields inherit
the value below them.

- `userBubble`: the complete user-message surface.
- `assistantBubble`: assistant answer text surfaces only.
- `processCard`: tool calls, thinking nodes, and their combined chain card.

Every layer may contain any of those three surface objects. Surface fields are:

| Field | Type and range | Applies to |
| --- | --- | --- |
| `backgroundColor` | `#RRGGBB` or `#RRGGBBAA` | all |
| `textColor` | `#RRGGBB` or `#RRGGBBAA` | all |
| `accentColor` | `#RRGGBB` or `#RRGGBBAA` | process card only |
| `borderColor` | `#RRGGBB` or `#RRGGBBAA` | all |
| `borderWidth` | 0–4 px | all |
| `cornerRadius` | 0–48 px | all |
| `paddingHorizontal` | 0–32 px | all |
| `paddingVertical` | 0–32 px | all |
| `shadowElevation` | 0–24 | all |
| `maxWidthPercent` | 40–100% | user/assistant bubbles only |

Numbers may be integers or decimals. CSS, HTML, JavaScript, URLs, selectors,
fonts, images, and remote resources are never accepted.

## Import and forward compatibility

The settings manager accepts pasted JSON, one local style file, a ZIP archive,
or a public GitHub URL. A bare repository URL follows that repository's default
branch. A `/tree/<branch>[/path]` URL selects an explicit branch and optional
subdirectory. ZIP and repository scans are recursive; when several files are
found, Cuplivo asks which ones to import before it validates the entire
selected batch.

A GitHub `/blob/<branch>/<path>.cuplivo-style.json` URL or the equivalent
`raw.githubusercontent.com` URL imports exactly one style file. Other hosts,
GitHub page types, and file suffixes are rejected. GitHub imports support only
public repositories and files.

Unknown fields and schema versions above v1 are retained in the original JSON
and reported as compatibility warnings, but only known v1 fields render. A
known field with an invalid type/value, or a document with no applicable v1
field, is rejected. Re-export preserves JSON data semantics, not original
whitespace or key order.

Limits: 64 KiB per style, 64 stored styles, 1 MiB combined original JSON, and
64 MiB/2000 entries per archive. Importing an existing `id` updates it without
changing the active selection. Import never activates a style automatically.
