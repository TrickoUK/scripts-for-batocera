#!/usr/bin/env python3
"""Find (and optionally remove) build artifacts no longer referenced by the
current board configs: stale downloads under dl/, orphaned per-board
output/<target>/build/ and output/<target>/per-package/<pkg>/ dirs, and
known nested staleness (e.g. an old kernel's modules still sitting inside
the current `linux` package's per-package snapshot after a version bump).

Uses Buildroot's own `show-info` target as the source of truth for what's
actually still needed, run directly against each board's already-generated
.config (no Docker, no build required).

Usage:
  scripts/linux/cleanup_build_artifacts.py                       # dry-run report
  scripts/linux/cleanup_build_artifacts.py --apply dl,build       # delete those categories
  scripts/linux/cleanup_build_artifacts.py --only nested --json
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
from collections import namedtuple

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

RESET = "\033[0m"
BOLD = "\033[1m"
YELLOW = "\033[1;33m"
RED = "\033[1;31m"

CATEGORIES = ["dl", "build", "per-package", "nested"]

ARCHIVE_EXTS = (".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst", ".tgz", ".zip", ".tar")
DL_SKIP_DIRS = {"br-cargo-home"}

# Buildroot-internal scratch dirs under output/<target>/build/ that are never
# packages and so never appear in show-info - confirmed via buildroot/Makefile
# (buildroot-config: Kconfig .config generation) and
# buildroot/support/scripts/genimage.sh (genimage.tmp: image-assembly scratch).
BUILD_DIR_SKIP = {"buildroot-config", "buildroot-fs", "genimage.tmp"}

# Narrow, explicitly-listed special cases for staleness that lives *inside*
# a still-current package's own per-package snapshot, keyed by a version
# subdirectory that Buildroot never prunes on its own. Not a generic
# per-package content differ - just the one real failure mode observed.
KNOWN_NESTED_PATTERNS = {
    "linux-kernel-modules": {
        "package": "linux",
        "relative_path": os.path.join("lib", "modules"),
        "current_version_fn": lambda info: info.get("linux", {}).get("version") or None,
    },
}

Candidate = namedtuple("Candidate", ["category", "board", "description", "paths", "size_bytes"])


def run_show_info(repo_root, target):
    out_dir = os.path.join(repo_root, "output", target)
    if not os.path.isfile(os.path.join(out_dir, ".config")):
        print(f"{RED}error:{RESET} {out_dir}/.config not found - has {target} been configured/built at least once?", file=sys.stderr)
        sys.exit(1)
    cmd = [
        "make", "--no-print-directory", "-C", os.path.join(repo_root, "buildroot"),
        f"O={out_dir}",
        f"BR2_EXTERNAL={repo_root}",
        f"BR2_EXTERNAL_BATOCERA_PATH={repo_root}",
        "show-info",
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as e:
        print(f"{RED}error:{RESET} show-info failed for {target}:\n{e.stderr[-2000:]}", file=sys.stderr)
        sys.exit(1)
    text = result.stdout
    start = text.index("{")
    end = text.rindex("}") + 1
    return json.loads(text[start:end])


def du_bytes(path):
    if os.path.isfile(path):
        try:
            return os.path.getsize(path)
        except OSError:
            return 0
    total = 0
    for dirpath, _dirnames, filenames in os.walk(path):
        for f in filenames:
            fp = os.path.join(dirpath, f)
            try:
                total += os.path.getsize(fp)
            except OSError:
                pass
    return total


def human_size(n):
    n = float(n)
    for unit in ("B", "K", "M", "G", "T"):
        if n < 1024 or unit == "T":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024


def scan_dl(repo_root, show_info_by_board):
    dl_root = os.path.join(repo_root, "dl")
    candidates = []
    if not os.path.isdir(dl_root):
        return candidates

    needed_by_dl_dir = {}
    all_dl_dirs = set()
    for info in show_info_by_board.values():
        for pkg in info.values():
            dld = pkg.get("dl_dir")
            if not dld:
                continue
            all_dl_dirs.add(dld)
            bucket = needed_by_dl_dir.setdefault(dld, set())
            for d in pkg.get("downloads", []):
                src = d.get("source")
                if src:
                    bucket.add(src)

    for name in sorted(os.listdir(dl_root)):
        if name in DL_SKIP_DIRS or name.startswith("."):
            continue
        full = os.path.join(dl_root, name)
        if not os.path.isdir(full):
            continue
        if name not in all_dl_dirs:
            candidates.append(Candidate(
                "dl", None,
                f"dl/{name}/ - package no longer referenced by any scanned board",
                [full], du_bytes(full)))
            continue
        needed = needed_by_dl_dir.get(name, set())
        for fname in sorted(os.listdir(full)):
            fpath = os.path.join(full, fname)
            if not os.path.isfile(fpath):
                continue  # e.g. a git/ object-cache dir - never touched here
            if not fname.lower().endswith(ARCHIVE_EXTS):
                continue
            if fname not in needed:
                candidates.append(Candidate(
                    "dl", None,
                    f"dl/{name}/{fname} - stale version, not needed by any scanned board",
                    [fpath], du_bytes(fpath)))
    return candidates


def scan_build(repo_root, target, info):
    build_root = os.path.join(repo_root, "output", target, "build")
    if not os.path.isdir(build_root):
        return []
    expected = set()
    for pkg in info.values():
        # stamp_dir/source_dir point at the top-level output/<target>/build/<pkg>-<version>/
        # dir; build_dir is NOT reliable for this - for cmake/meson/etc. packages it points
        # at a nested out-of-tree build subdir instead (e.g. ".../rpcs3-v0.0.41/buildroot-build").
        sd = pkg.get("stamp_dir") or pkg.get("source_dir")
        if sd:
            expected.add(os.path.basename(sd.rstrip("/")))

    candidates = []
    for name in sorted(os.listdir(build_root)):
        if name in BUILD_DIR_SKIP:
            continue
        full = os.path.join(build_root, name)
        if not os.path.isdir(full):
            continue  # stray files like build-time.log
        if name not in expected:
            candidates.append(Candidate(
                "build", target,
                f"output/{target}/build/{name}/ - not a current package build dir",
                [full], du_bytes(full)))
    return candidates


def scan_per_package(repo_root, target, info):
    pp_root = os.path.join(repo_root, "output", target, "per-package")
    if not os.path.isdir(pp_root):
        return []
    expected = set(info.keys())

    candidates = []
    for name in sorted(os.listdir(pp_root)):
        full = os.path.join(pp_root, name)
        if not os.path.isdir(full):
            continue
        if name not in expected:
            candidates.append(Candidate(
                "per-package", target,
                f"output/{target}/per-package/{name}/ - package no longer in current config",
                [full], du_bytes(full)))
    return candidates


def scan_nested(repo_root, target, info):
    candidates = []
    for check_name, spec in KNOWN_NESTED_PATTERNS.items():
        current = spec["current_version_fn"](info)
        if not current:
            continue
        pkg = spec["package"]
        rel = spec["relative_path"]
        pp_dir = os.path.join(repo_root, "output", target, "per-package", pkg, "target", rel)
        merged_dir = os.path.join(repo_root, "output", target, "target", rel)

        stale_versions = set()
        for base_dir in (pp_dir, merged_dir):
            if not os.path.isdir(base_dir):
                continue
            for entry in os.listdir(base_dir):
                if entry != current and os.path.isdir(os.path.join(base_dir, entry)):
                    stale_versions.add(entry)

        for ver in sorted(stale_versions):
            paths = [os.path.join(base_dir, ver) for base_dir in (pp_dir, merged_dir)
                     if os.path.isdir(os.path.join(base_dir, ver))]
            if not paths:
                continue
            size = sum(du_bytes(p) for p in paths)
            rels = ", ".join(os.path.relpath(p, repo_root) for p in paths)
            candidates.append(Candidate(
                "nested", target,
                f"{check_name}: stale version {ver} (current is {current}) - {rels}",
                paths, size))
    return candidates


def print_report(candidates, use_json):
    if use_json:
        print(json.dumps([c._asdict() for c in candidates], indent=2))
        return

    if not candidates:
        print("No cleanup candidates found.")
        return

    by_cat = {}
    for c in candidates:
        by_cat.setdefault(c.category, []).append(c)

    total = 0
    for cat in CATEGORIES:
        items = by_cat.get(cat, [])
        if not items:
            continue
        cat_total = sum(c.size_bytes for c in items)
        total += cat_total
        print(f"\n{BOLD}{cat}{RESET} ({len(items)} candidate(s), {human_size(cat_total)}):")
        for c in items:
            print(f"  {YELLOW}{human_size(c.size_bytes):>8}{RESET}  {c.description}")

    print(f"\n{BOLD}Total reclaimable: {human_size(total)}{RESET}")


def apply_candidates(candidates, categories):
    removed = 0
    for c in candidates:
        if c.category not in categories:
            continue
        for p in c.paths:
            if os.path.isfile(p) or os.path.islink(p):
                os.remove(p)
            elif os.path.isdir(p):
                shutil.rmtree(p)
        removed += c.size_bytes
    return removed


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--boards", default="x86_64-focused,zen3-focused",
                         help="comma-separated board target names (default: %(default)s)")
    parser.add_argument("--only", default=",".join(CATEGORIES),
                         help=f"comma-separated categories to scan: {','.join(CATEGORIES)} (default: all)")
    parser.add_argument("--apply", default=None,
                         help="comma-separated categories to actually delete (default: none, dry-run only)")
    parser.add_argument("--yes", action="store_true", help="skip the confirmation prompt before deleting")
    parser.add_argument("--json", action="store_true", help="machine-readable report, implies no deletion prompt output")
    args = parser.parse_args()

    boards = [b.strip() for b in args.boards.split(",") if b.strip()]
    only = {c.strip() for c in args.only.split(",") if c.strip()}
    apply_cats = {c.strip() for c in args.apply.split(",") if c.strip()} if args.apply else set()

    unknown = (only | apply_cats) - set(CATEGORIES)
    if unknown:
        print(f"{RED}error:{RESET} unknown category/categories: {', '.join(sorted(unknown))}", file=sys.stderr)
        sys.exit(1)

    if not args.json:
        print(f"Gathering show-info for: {', '.join(boards)}...", file=sys.stderr)
    show_info_by_board = {board: run_show_info(REPO_ROOT, board) for board in boards}

    candidates = []
    if "dl" in only:
        candidates += scan_dl(REPO_ROOT, show_info_by_board)
    for board in boards:
        info = show_info_by_board[board]
        if "build" in only:
            candidates += scan_build(REPO_ROOT, board, info)
        if "per-package" in only:
            candidates += scan_per_package(REPO_ROOT, board, info)
        if "nested" in only:
            candidates += scan_nested(REPO_ROOT, board, info)

    print_report(candidates, args.json)

    if not apply_cats:
        return

    to_apply = [c for c in candidates if c.category in apply_cats]
    if not to_apply:
        print("\nNothing to apply for the requested categories.")
        return

    if not args.yes:
        print(f"\n{BOLD}About to delete {len(to_apply)} candidate(s) "
              f"in categories: {', '.join(sorted(apply_cats))}{RESET}")
        resp = input("Type 'yes' to confirm: ")
        if resp.strip().lower() != "yes":
            print("Aborted.")
            return

    removed = apply_candidates(candidates, apply_cats)
    print(f"\nRemoved {human_size(removed)}.")


if __name__ == "__main__":
    main()
