#!/bin/bash
set -u
cd "$(dirname "$0")" || exit 1
FORK_DIR="/var/mnt/work/batocera-build/libretro-mame"

set -a
source ./topic.env
set +a

# notify $NOTIFYTOPIC and stop, rather than carrying on to the image build
fail() {
    echo "error: $1" >&2
    curl -H "Title: 🕹️ MAME refresh failed 😞" -d "$1" $NOTIFYTOPIC
    exit 1
}

# drop the uncommitted patches applied by sync-mame-patches.sh, then sync the fork
git -C "$FORK_DIR" checkout -- . || fail "git checkout in libretro-mame failed"
git -C "$FORK_DIR" pull || fail "git pull in libretro-mame failed"

# buildroot's OVERRIDE_SRCDIR sync is `rsync -au` with no --delete, so files
# upstream removed/moved linger in the build copy and can shadow the real ones
# (e.g. a stale src/devices/video/vector.h hiding src/emu/vector.h). Delete-only
# prune of the source trees (hash/ and plugins/ are copied into the image as-is).
# Not a whole-tree --delete: the build copy also holds the build products
# (build/, libretro/ objs, the .so, stamps, generated .flt/.mo) that make the
# rebuild incremental. genie's own build output and pycache are kept too.
BUILD_COPY="output/${TARGET:-zen3-focused}/build/libretro-mame-custom"
if [ -d "$BUILD_COPY" ]; then
    for d in src 3rdparty scripts hash plugins; do
        rsync -r --delete --existing --ignore-existing \
            --exclude=.git --exclude=__pycache__ \
            --exclude=/genie/bin --exclude=/genie/build \
            "$FORK_DIR/$d/" "$BUILD_COPY/$d/" || fail "pruning stale files from the libretro-mame build copy failed"
    done
fi

./sync-mame-patches.sh
make "${TARGET:-zen3-focused}-build" CMD="libretro-mame-rebuild" \
    || fail "libretro-mame failed to compile (exit $?)"
./rebuild.sh
