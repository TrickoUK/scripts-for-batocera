#!/bin/bash
#
# Usage: ./mame-refresh.sh [--batch] [--cores N] [<rebuild.sh args>...]
#   --batch, -b   non-interactive (no TTY) run, e.g. under nohup or an agent's
#                 shell: passes BATCH_MODE=1 to the libretro-mame make and
#                 --batch to rebuild.sh. A pre-exported BATCH_MODE=1 does the
#                 same.
#   --cores N, -j N  compile with N parallel jobs instead of every core, to
#                 leave the rest free for other work. Applies to both the
#                 libretro-mame compile and the image build (passed on to
#                 rebuild.sh). Default: all cores.
#                 Any other arguments go straight to rebuild.sh
#                 (e.g. --quick). Pick the board with TARGET=<target>, which
#                 both steps read (default zen3-focused).
set -u
cd "$(dirname "$0")" || exit 1

BATCH_MODE="${BATCH_MODE:-}"
REBUILD_ARGS=()
CORES=""
while [ $# -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in
        --batch|-b) BATCH_MODE=1 ;;
        --cores|-j)
            if [ $# -eq 0 ]; then
                echo "error: $arg needs a number of cores" >&2
                exit 1
            fi
            CORES="$1"
            shift
            ;;
        --cores=*|-j=*) CORES="${arg#*=}" ;;
        *) REBUILD_ARGS+=("$arg") ;;
    esac
done
if [ -n "$CORES" ]; then
    if ! [[ "$CORES" =~ ^[1-9][0-9]*$ ]]; then
        echo "error: --cores needs a positive whole number, got '$CORES'" >&2
        exit 1
    fi
    TOTAL_CORES="$(nproc)"
    if [ "$CORES" -gt "$TOTAL_CORES" ]; then
        echo "warning: --cores $CORES is more than the $TOTAL_CORES available, using $TOTAL_CORES" >&2
        CORES="$TOTAL_CORES"
    fi
    # the Makefile takes MAKE_JLEVEL/MAKE_LLEVEL from the environment (?=), so
    # this limits the libretro-mame compile below; rebuild.sh gets it too
    export MAKE_JLEVEL="$CORES" MAKE_LLEVEL="$CORES"
    REBUILD_ARGS=(--cores "$CORES" "${REBUILD_ARGS[@]}")
    echo "Using $CORES of $TOTAL_CORES cores for compilation"
fi
[ -n "$BATCH_MODE" ] && REBUILD_ARGS=(--batch "${REBUILD_ARGS[@]}")
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
make "${TARGET:-zen3-focused}-build" CMD="libretro-mame-rebuild" BATCH_MODE="$BATCH_MODE" \
    || fail "libretro-mame failed to compile (exit $?)"
./rebuild.sh "${REBUILD_ARGS[@]}"
