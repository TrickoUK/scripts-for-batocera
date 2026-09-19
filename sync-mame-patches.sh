#!/bin/bash
#
# sync-mame-patches.sh — apply this repo's libretro-mame .patch files onto the
# local fork checkout's working tree.
#
# Why: libretro-mame.mk now builds via LIBRETRO_MAME_OVERRIDE_SRCDIR, which
# makes buildroot skip its own download/extract/patch step entirely (see
# buildroot/package/pkg-generic.mk). So these patches - the durable, canonical
# fixes, kept as .patch files here so they still work if we ever switch back
# to a plain libretro/mame tarball pin - no longer get applied automatically.
# This script applies them directly to the fork checkout instead, left
# uncommitted there so the fork's own git history/PRs stay clean of them.
#
# Run this once now, and again any time the fork checkout is pulled/rebased
# from upstream, before building.
#
# Usage: ./sync-mame-patches.sh

set -u

PATCH_DIR="$(cd "$(dirname "$0")" && pwd)/package/batocera/emulators/retroarch/libretro/libretro-mame"
FORK_DIR="/var/mnt/work/batocera-build/libretro-mame-fork"

if [ ! -d "$FORK_DIR" ]; then
    echo "error: $FORK_DIR does not exist" >&2
    exit 1
fi

shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
shopt -u nullglob

if [ ${#patches[@]} -eq 0 ]; then
    echo "no .patch files found in $PATCH_DIR" >&2
    exit 1
fi

failed=()

cd "$FORK_DIR" || exit 1

for p in "${patches[@]}"; do
    name="$(basename "$p")"

    if git apply --check -R -p1 "$p" >/dev/null 2>&1; then
        echo "skip:   $name (already applied)"
        continue
    fi

    if git apply --check -p1 "$p" >/dev/null 2>&1; then
        git apply -p1 "$p"
        echo "applied: $name"
    else
        echo "FAILED: $name (does not apply - needs re-porting against current source)"
        failed+=("$name")
    fi
done

if [ ${#failed[@]} -gt 0 ]; then
    echo
    echo "The following patches could not be applied and were skipped:"
    printf '  %s\n' "${failed[@]}"
    exit 1
fi
