#!/bin/bash
#
# apply-patches.sh — bring the working tree's local patches
# (board/batocera/x86/local-patches/*.patch) up to date.
#
# These patches wire fork-only features into files this repo shares with
# upstream batocera (e.g. the top-level Config.in, or configgen's
# importer.py) without committing to them directly, so the shared files
# stay byte-for-byte upstream-clean and merges from batocera-linux:master
# don't conflict. A single patch file may touch more than one shared file
# for the same feature (e.g. standalone-mame.patch covers both Config.in
# and importer.py) — git apply treats that as one atomic unit. See "The
# local Config.in patches" in USER-INSTRUCTIONS.md.
#
# Not everything that looks like it needs this treatment does: some
# shared files (es_systems.yml's per-system emulators: sub-block, for
# one) are validated-but-unused by the code that reads them. Check
# whether an edit is actually load-bearing before reaching for a patch —
# dead code doesn't need to be preserved at all, patched or committed.
#
# Safe to re-run any time: each patch is checked before acting, so an
# already-applied patch is left alone and only missing ones get applied.
# This is the one place new local patches get registered — just drop a
# new *.patch file into board/batocera/x86/local-patches/ and it's picked
# up automatically, no edit to this script required.
#
# Usage: ./apply-patches.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${REPO_ROOT}/board/batocera/x86/local-patches"

cd "${REPO_ROOT}"

shopt -s nullglob
PATCHES=("${PATCH_DIR}"/*.patch)
shopt -u nullglob

if [ ${#PATCHES[@]} -eq 0 ]; then
    echo "No patches found in ${PATCH_DIR}."
    exit 0
fi

applied_count=0
already_count=0
failed_count=0

for patch in "${PATCHES[@]}"; do
    name="$(basename "$patch")"

    if git apply --check "$patch" 2>/dev/null; then
        git apply "$patch"
        echo "applied:         ${name}"
        applied_count=$((applied_count + 1))
    elif git apply --reverse --check "$patch" 2>/dev/null; then
        echo "already applied: ${name}"
        already_count=$((already_count + 1))
    else
        echo "CONFLICT:        ${name} — does not apply or reverse cleanly" >&2
        echo "  the file(s) it targets may have changed since this patch was written." >&2
        echo "  reconcile or regenerate ${name} by hand (see USER-INSTRUCTIONS.md)." >&2
        failed_count=$((failed_count + 1))
    fi
done

echo
echo "Summary: ${applied_count} applied, ${already_count} already applied, ${failed_count} conflicts."

if [ "$failed_count" -gt 0 ]; then
    exit 1
fi
