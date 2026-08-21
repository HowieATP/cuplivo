#!/usr/bin/env python3
"""One-off verification gate for the semantic-color migration (#300).

Scans lib/**/*.dart for hardcoded color idioms. Two buckets:

  * MUST-GO idioms (the migration was supposed to eliminate these): the
    surfaceFill/surfaceCard/status/text-muted/search-highlight families.
    Any remaining site is a migration miss and makes this tool exit 1.
  * INFORMATIONAL deliberate fixed colors: full-opacity Colors.white/black,
    CupertinoColors, and general Color(0x...) literals. These are printed for
    review only and must carry a `color-gate: ignore` marker where they are a
    truly intentional fixed color.

This mirrors upstream Kelivo's `tool/check_colors.sh` gate which was removed
as "one-off migration verification tooling". It is intentionally NOT wired
into CI — run it manually after theme-token changes:

    python3 tool/check_colors.py

Always excluded:
  - lib/theme/**  -> palette definitions, static schemes, semantic token
                     derivation, design tokens
  - lines with `color-gate: ignore`  -> deliberate fixed colors
  - transparent literals (Colors.transparent, CupertinoColors.transparent,
    Color(0x00000000))
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
LIB = ROOT / "lib"

IGNORE_MARKER = "color-gate: ignore"

# Idiom families the semantic-color migration was supposed to replace.
MUST_GO = re.compile(
    r"(?<!\w)Colors\.(white10|white12|white24|white30|white38|white54|white70|"
    r"black26|black38|black45|black54|black87|grey|grey\.shade|red|redAccent|"
    r"red\.shade|green|green\.shade|orange|amber|blue|teal|purple|indigo|pink|"
    r"brown|cyan|yellow)\b"
    r"|Color\(0xFF(?:F2F3F5|F7F7F9|1C1C1E|141414|EBEBEB|F1F3F5|F6F7F9|"
    r"F8F8FA|DADDE2|DDE2E8|D9DDE2|FFD700|B8860B)\)"
)

# Deliberate fixed colors / general literals (informational).
INFORMATIONAL = re.compile(
    r"(?<!\w)Colors\.(white|black)\b"
    r"|(?<!\w)CupertinoColors\.\w+"
    r"|Color\(0x[0-9a-fA-F]{6,8}\)"
    r"|Color\(0X[0-9a-fA-F]{6,8}\)"
)

TRANSPARENT = re.compile(
    r"(?<!\w)Colors\.transparent\b"
    r"|(?<!\w)CupertinoColors\.transparent\b"
    r"|Color\(0x[0]+\)"
)


def scan():
    must_go = []
    info = []
    for path in sorted(LIB.rglob("*.dart")):
        rel = path.relative_to(ROOT).as_posix()
        if rel.startswith("lib/theme/"):
            continue
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue
        for lineno, line in enumerate(lines, start=1):
            # A `color-gate: ignore` marker may sit on the same line or on the
            # immediately-preceding line (standalone comment lines are stable
            # under dart format, unlike trailing comments on long expressions).
            prev_line = lines[lineno - 2] if lineno >= 2 else ""
            marked = IGNORE_MARKER in line or IGNORE_MARKER in prev_line
            if marked:
                continue
            for match in MUST_GO.finditer(line):
                if TRANSPARENT.search(match.group(0)):
                    continue
                must_go.append(f"{rel}:{lineno}: {match.group(0)}")
            for match in INFORMATIONAL.finditer(line):
                if TRANSPARENT.search(match.group(0)):
                    continue
                # Don't double-report a literal already flagged as must-go.
                if match.group(0) in [
                    m.group(0) for m in MUST_GO.finditer(line)
                ]:
                    continue
                info.append(f"{rel}:{lineno}: {match.group(0)}")
    return must_go, info


def main() -> int:
    must_go, info = scan()
    if must_go:
        print(f"{len(must_go)} MUST-GO migration miss(es):")
        for h in must_go:
            print("  " + h)
        print(
            "\nThese are migration misses. Either migrate them to semantic "
            "tokens, or (rarely) mark a deliberate exception with "
            f"`// {IGNORE_MARKER}`."
        )
    else:
        print("No must-go migration misses in lib/ (excluding lib/theme/).")
    if info:
        print(f"\n{len(info)} informational fixed-color site(s) — review only:")
        for h in info[:40]:
            print("  " + h)
        if len(info) > 40:
            print(f"  ... and {len(info) - 40} more.")
    return 1 if must_go else 0


if __name__ == "__main__":
    sys.exit(main())
