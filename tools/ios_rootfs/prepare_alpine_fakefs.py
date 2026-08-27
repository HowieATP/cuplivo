#!/usr/bin/env python3
"""Build an iSH fakefs Alpine rootfs zip for the Cuplivo iOS Linux sandbox.

Replicates the semantics of iSH's `fakefsify` (ish/tools/fakefs.c) in pure
Python so no meson / libarchive / Xcode toolchain is needed:

  * fakefs layout: `<root>/data/<guest path>` (path-based) + `<root>/meta.db`
  * meta.db schema (must match ish/fs/fake-db.c):
        create table meta (id integer unique default 0, db_inode integer);
        insert into meta (db_inode) values (0);
        create table stats (inode integer primary key, stat blob);
        create table paths (path blob primary key,
                            inode integer references stats(inode));
        create index inode_to_path on paths (inode, path);
        pragma user_version=3;
  * stat blob = struct ish_stat { u32 mode, u32 uid, u32 gid, u32 rdev }
    serialized little-endian (16 bytes)
  * symlinks are stored as regular files whose CONTENT is the symlink target
    (fakefs symlink model); the S_IFLNK mode lives in meta.db
  * paths are normalized exactly like fakefsify: leading '/' kept, `.` and
    trailing '/' collapsed, `..` rejected (path traversal safety)

After importing the Alpine minirootfs tarball the script applies the same
kind of first-boot configuration OpenMinis applies to its Alpine rootfs
(DNS, apk repositories, profile, guest dirs) plus Cuplivo's `/workspace`
bind-mount target directory, then zips the result.

Usage:
  python3 tools/ios_rootfs/prepare_alpine_fakefs.py \
      [--version 3.21] [--patch 0] \
      [--mirror auto|official|aliyun|ustc|sjtu|tuna|<url-prefix>] \
      [--input /path/to/alpine-minirootfs.tar.gz] \
      [--output ios/sandbox/resources/alpine-rootfs.zip]
"""

from __future__ import annotations

import argparse
import io
import os
import shutil
import sqlite3
import struct
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

ALPINE_ARCH = "aarch64"

MIRRORS = {
    "official": "https://dl-cdn.alpinelinux.org/alpine",
    "aliyun": "https://mirrors.aliyun.com/alpine",
    "ustc": "https://mirrors.ustc.edu.cn/alpine",
    "sjtu": "https://mirror.sjtu.edu.cn/alpine",
    "tuna": "https://mirrors.tuna.tsinghua.edu.cn/alpine",
}
AUTO_ORDER = ["official", "aliyun", "ustc", "sjtu", "tuna"]

SCHEMA = """
create table meta (id integer unique default 0, db_inode integer);
insert into meta (db_inode) values (0);
create table stats (inode integer primary key, stat blob);
create table paths (path blob primary key, inode integer references stats(inode));
create index inode_to_path on paths (inode, path);
pragma user_version=3;
"""

PUBLIC_DNS = ["1.1.1.1", "8.8.8.8", "223.5.5.5"]

PROFILE_APPENDIX = """
# Cuplivo sandbox configuration
export PS1='\\u@cuplivo:\\w\\$ '
export TERM=xterm-256color
export HOME=/root
export LANG=C.UTF-8
export CHARSET=UTF-8
export PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
"""

# Guest directories that must exist even if the tarball omits them.
# `workspace` is the bind-mount target for the host workspace directory.
EXTRA_DIRS = ["dev", "proc", "sys", "tmp", "run", "root", "home", "workspace"]


def log(msg: str) -> None:
    print(msg, flush=True)


# tarfile strips file-type bits from TarInfo.mode; fakefsify's
# archive_entry_mode() includes them, so rebuild from TarInfo.type.
_TYPE_BITS = {
    tarfile.REGTYPE: 0o100000,
    tarfile.AREGTYPE: 0o100000,
    tarfile.LNKTYPE: 0o100000,
    tarfile.SYMTYPE: 0o120000,
    tarfile.DIRTYPE: 0o040000,
    tarfile.CHRTYPE: 0o020000,
    tarfile.BLKTYPE: 0o060000,
    tarfile.FIFOTYPE: 0o010000,
}


def entry_mode(m: tarfile.TarInfo) -> int:
    return _TYPE_BITS.get(m.type, 0) | (m.mode & 0o7777)


def normalize_path(raw: str) -> str | None:
    """Port of fakefsify's path_normalize. Returns None on traversal."""
    out: list[str] = []
    i, n = 0, len(raw)
    while i < n:
        while i < n and raw[i] == "/":
            i += 1
        if i >= n:
            break
        if raw[i] == "." and i + 1 < n and raw[i + 1] == "." and (
            i + 2 >= n or raw[i + 2] == "/"
        ):
            return None
        if raw[i] == "." and (i + 1 >= n or raw[i + 1] == "/"):
            i += 1
            continue
        start = i
        while i < n and raw[i] != "/":
            i += 1
        out.append(raw[start:i])
    if not out:
        return ""
    return "/" + "/".join(out)


def download_tarball(version: str, patch: int, mirror: str, dest: str) -> None:
    name = f"alpine-minirootfs-{version}.{patch}-{ALPINE_ARCH}.tar.gz"
    if mirror == "auto":
        candidates = [MIRRORS[k] for k in AUTO_ORDER]
    elif mirror in MIRRORS:
        candidates = [MIRRORS[mirror]]
    else:
        candidates = [mirror.rstrip("/")]
    last_err: Exception | None = None
    for base in candidates:
        url = f"{base}/v{version}/releases/{ALPINE_ARCH}/{name}"
        log(f"downloading {url}")
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "cuplivo-rootfs-builder/1.0"})
            with urllib.request.urlopen(req, timeout=120) as resp, open(dest, "wb") as f:
                shutil.copyfileobj(resp, f)
            if os.path.getsize(dest) < 100_000:
                raise IOError(f"suspiciously small download ({os.path.getsize(dest)} bytes)")
            return
        except Exception as e:  # noqa: BLE001 - mirror fallback by design
            last_err = e
            log(f"  failed: {e}")
    raise SystemExit(f"all mirrors failed; last error: {last_err}")


class FakefsBuilder:
    def __init__(self, root: str) -> None:
        self.root = root
        self.data = os.path.join(root, "data")
        os.makedirs(self.data, exist_ok=True)
        self.db = sqlite3.connect(os.path.join(root, "meta.db"))
        self.db.executescript(SCHEMA)
        self._paths_seen: dict[str, int] = {}
        self._file_by_path: dict[str, str] = {}

    # -- meta.db helpers -------------------------------------------------
    def _insert_stat(self, mode: int, uid: int, gid: int, rdev: int) -> int:
        blob = struct.pack("<IIII", mode & 0xFFFFFFFF, uid & 0xFFFFFFFF,
                           gid & 0xFFFFFFFF, rdev & 0xFFFFFFFF)
        cur = self.db.execute("insert into stats (stat) values (?)", (blob,))
        return int(cur.lastrowid)

    def _insert_path(self, path: str, inode: int) -> None:
        self.db.execute(
            "insert or replace into paths values (?, ?)", (path.encode(), inode)
        )
        self._paths_seen[path] = inode

    def add_entry(self, path: str, mode: int, uid: int, gid: int, rdev: int) -> int:
        inode = self._insert_stat(mode, uid, gid, rdev)
        self._insert_path(path, inode)
        return inode

    def host_path(self, path: str) -> str:
        rel = path.lstrip("/")
        return os.path.join(self.data, rel) if rel else self.data

    def ensure_parent_dirs(self, path: str) -> None:
        host = self.host_path(path)
        parent = os.path.dirname(host)
        os.makedirs(parent, exist_ok=True)

    # -- import ----------------------------------------------------------
    def import_tar(self, tar_path: str) -> int:
        count = 0
        pending_hardlinks: list[tuple[str, str]] = []
        with tarfile.open(tar_path, "r:gz") as tf:
            for m in tf.getmembers():
                path = normalize_path(m.name)
                if path is None:
                    log(f"warning: skipped possible path traversal {m.name!r}")
                    continue
                if m.islnk():
                    target = normalize_path(m.linkname)
                    if target is None:
                        log(f"warning: skipped hardlink traversal {m.name!r}")
                        continue
                    pending_hardlinks.append((path, target))
                    continue
                self.ensure_parent_dirs(path)
                host = self.host_path(path)
                if m.isdir():
                    os.makedirs(host, exist_ok=True)
                elif m.isreg():
                    with open(host, "wb") as f:
                        src = tf.extractfile(m)
                        if src is not None:
                            shutil.copyfileobj(src, f)
                    self._file_by_path[path] = host
                elif m.issym():
                    # fakefs symlink model: regular file containing the target
                    with open(host, "w", encoding="utf-8") as f:
                        f.write(m.linkname)
                elif m.isdev() or m.isfifo():
                    log(f"warning: skipping device/fifo entry {path}")
                    continue
                else:
                    log(f"warning: skipping unknown entry type {m.name!r}")
                    continue
                try:
                    os.utime(host, (m.mtime, m.mtime))
                except OSError:
                    pass
                rdev = 0
                if m.isdev():
                    rdev = (m.devmajor << 8) | m.devminor
                self.add_entry(path, entry_mode(m), m.uid, m.gid, rdev)
                count += 1
        # Hardlinks: same inode as target; host file is a copy (zip cannot
        # preserve hardlinks; the guest reads by path, not inode).
        for path, target in pending_hardlinks:
            inode = self._paths_seen.get(target)
            if inode is None:
                log(f"warning: hardlink target missing for {path} -> {target}")
                continue
            target_host = self._file_by_path.get(target)
            if target_host is not None:
                self.ensure_parent_dirs(path)
                shutil.copyfile(target_host, self.host_path(path))
            self._insert_path(path, inode)
            count += 1
        if "" not in self._paths_seen:
            self.add_entry("", 0o40755, 0, 0, 0)
        self.db.commit()
        return count

    # -- post-import configuration ----------------------------------------
    def ensure_dir(self, path: str, mode: int = 0o40755) -> None:
        host = self.host_path(path)
        os.makedirs(host, exist_ok=True)
        if path not in self._paths_seen:
            self.add_entry(path, mode, 0, 0, 0)

    def write_file(self, path: str, content: bytes, mode: int = 0o100644) -> None:
        self.ensure_parent_dirs(path)
        host = self.host_path(path)
        with open(host, "wb") as f:
            f.write(content)
        if path in self._paths_seen:
            inode = self._paths_seen[path]
            blob = struct.pack("<IIII", mode, 0, 0, 0)
            self.db.execute("update stats set stat = ? where inode = ?", (blob, inode))
        else:
            self.add_entry(path, mode, 0, 0, 0)

    def read_file(self, path: str) -> bytes | None:
        host = self.host_path(path)
        if not os.path.isfile(host):
            return None
        with open(host, "rb") as f:
            return f.read()

    def configure(self, version: str) -> None:
        for d in EXTRA_DIRS:
            self.ensure_dir("/" + d)

        dns = "".join(f"nameserver {s}\n" for s in PUBLIC_DNS)
        self.write_file("/etc/resolv.conf", dns.encode())

        repos = (
            f"https://dl-cdn.alpinelinux.org/alpine/v{version}/main\n"
            f"https://dl-cdn.alpinelinux.org/alpine/v{version}/community\n"
        )
        self.write_file("/etc/apk/repositories", repos.encode())

        passwd = self.read_file("/etc/passwd")
        if passwd is not None:
            lines = passwd.decode(errors="replace").splitlines()
            fixed = []
            for line in lines:
                if line.startswith("root:"):
                    line = "root:x:0:0:root:/root:/bin/sh"
                fixed.append(line)
            self.write_file("/etc/passwd", ("\n".join(fixed) + "\n").encode())

        profile = self.read_file("/etc/profile") or b""
        if b"Cuplivo sandbox configuration" not in profile:
            self.write_file("/etc/profile", profile + PROFILE_APPENDIX.encode())
        self.db.commit()

    def finalize(self) -> None:
        self.db.execute("vacuum")
        self.db.close()


def verify(root: str) -> None:
    db = sqlite3.connect(os.path.join(root, "meta.db"))
    try:
        (n_paths,) = db.execute("select count(*) from paths").fetchone()
        (n_stats,) = db.execute("select count(*) from stats").fetchone()
        (uv,) = db.execute("pragma user_version").fetchone()
        assert uv == 3, f"user_version={uv}"
        for probe in ["/bin/sh", "/bin/busybox", "/etc/passwd", "/etc/apk/repositories",
                      "/lib/ld-musl-aarch64.so.1", "/workspace", ""]:
            row = db.execute(
                "select inode from paths where path = ?", (probe.encode(),)
            ).fetchone()
            assert row is not None, f"missing meta.db entry for {probe!r}"
        # stat blob sanity for /bin/busybox: regular file, executable
        row = db.execute(
            "select s.stat from stats s natural join paths p where p.path = ?",
            (b"/bin/busybox",),
        ).fetchone()
        mode = struct.unpack("<IIII", row[0])[0]
        assert mode & 0o170000 == 0o100000 and mode & 0o111, f"/bin/busybox mode {oct(mode)}"
        # /bin/sh is a symlink to busybox: S_IFLNK mode, target stored as file content
        row = db.execute(
            "select s.stat from stats s natural join paths p where p.path = ?",
            (b"/bin/sh",),
        ).fetchone()
        mode = struct.unpack("<IIII", row[0])[0]
        assert mode & 0o170000 == 0o120000, f"/bin/sh mode {oct(mode)}"
        host_sh = os.path.join(root, "data", "bin", "sh")
        with open(host_sh, "r", encoding="utf-8") as f:
            assert f.read() == "/bin/busybox", "/bin/sh symlink content mismatch"
        # symlink model sanity: /bin/ls -> busybox target stored as file content
        host_ls = os.path.join(root, "data", "bin", "ls")
        assert os.path.isfile(host_ls), "/bin/ls missing on disk"
        with open(host_ls, "r", encoding="utf-8") as f:
            assert f.read() == "/bin/busybox", "symlink content mismatch"
        assert os.path.isfile(os.path.join(root, "data", "bin", "busybox"))
    finally:
        db.close()
    log(f"verify OK: {n_paths} paths, {n_stats} stats rows")


def build_zip(root: str, out_zip: str) -> None:
    os.makedirs(os.path.dirname(out_zip) or ".", exist_ok=True)
    if os.path.exists(out_zip):
        os.remove(out_zip)
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        zf.writestr(".arch", ALPINE_ARCH)
        base = os.path.abspath(root)
        for dirpath, dirnames, filenames in os.walk(base):
            rel_dir = os.path.relpath(dirpath, base)
            for name in dirnames:
                rel = os.path.join(rel_dir, name) if rel_dir != "." else name
                info = zipfile.ZipInfo(rel.replace(os.sep, "/") + "/")
                info.external_attr = (0o40755 << 16) | 0x10
                zf.writestr(info, b"")
            for name in filenames:
                host = os.path.join(dirpath, name)
                rel = os.path.join(rel_dir, name) if rel_dir != "." else name
                info = zipfile.ZipInfo.from_file(host, rel.replace(os.sep, "/"))
                info.compress_type = zipfile.ZIP_DEFLATED
                st = os.stat(host)
                info.external_attr = ((int(st.st_mode) & 0xFFFF) << 16)
                with open(host, "rb") as f:
                    zf.writestr(info, f.read())
    log(f"zip written: {out_zip} ({os.path.getsize(out_zip)} bytes)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--version", default="3.21")
    ap.add_argument("--patch", type=int, default=0)
    ap.add_argument("--mirror", default="auto")
    ap.add_argument("--input", help="use a local minirootfs tarball instead of downloading")
    ap.add_argument("--output", default="ios/sandbox/resources/alpine-rootfs.zip")
    ap.add_argument("--keep-tmp", action="store_true")
    args = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="cuplivo-rootfs-")
    tarball = os.path.join(tmp, "alpine.tar.gz")
    try:
        if args.input:
            tarball = args.input
        else:
            download_tarball(args.version, args.patch, args.mirror, tarball)

        rootfs = os.path.join(tmp, "alpine-rootfs")
        builder = FakefsBuilder(rootfs)
        n = builder.import_tar(tarball)
        log(f"imported {n} entries")
        builder.configure(args.version)
        builder.finalize()
        verify(rootfs)
        build_zip(rootfs, args.output)
    finally:
        if not args.keep_tmp:
            shutil.rmtree(tmp, ignore_errors=True)
    log("done")


if __name__ == "__main__":
    main()
