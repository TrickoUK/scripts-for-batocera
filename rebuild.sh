#!/bin/bash
#
# rebuild.sh — refresh the ES/configgen pipeline, then do a full image
# build for the given target, notifying $NOTIFYTOPIC on completion/failure.
#
# Usage: ./rebuild.sh [--batch] [<target>]
#   <target>      buildroot target to build, e.g. x86_64-focused (default)
#                 or zen3-focused. Passed through to refresh-board-es.sh
#                 (as TARGET) and used for the `<target>-build` make target.
#   --batch, -b   pass BATCH_MODE=1 to the build (non-interactive Docker
#                 mode). Required when run with no attached TTY — e.g. via
#                 `nohup ./rebuild.sh &`, cron, or an agent's background
#                 shell — otherwise `docker run -t -i` fails with "cannot
#                 attach stdin to a TTY-enabled container because stdin is
#                 not a terminal". Omit for a normal interactive terminal
#                 run.

set -a
source "$(dirname "$0")/topic.env"
set +a

BATCH_MODE="${BATCH_MODE:-}"
TARGET="${TARGET:-x86_64-focused}"
for arg in "$@"; do
    case "$arg" in
        --batch|-b) BATCH_MODE=1 ;;
        -h|--help)
            echo "Usage: $0 [--batch] [<target>]"
            echo "  <target>      buildroot target to build (default: x86_64-focused)"
            echo "  --batch, -b   set BATCH_MODE=1 (required for non-interactive/no-TTY runs)"
            exit 0
            ;;
        -*)
            echo "error: unrecognized argument: $arg" >&2
            exit 1
            ;;
        *) TARGET="$arg" ;;
    esac
done

TARGET="$TARGET" ./refresh-board-es.sh

#PARALLEL_BUILD=y make "${TARGET}-build" BATCH_MODE="$BATCH_MODE" && ./update-usb.sh --auto
make "${TARGET}-build" BATCH_MODE="$BATCH_MODE"
EC=$?

if [ $EC -eq 0 ]; then
    # Disabled 2026-08-02: post-build-clean.sh wipes output/<target>/images/
    # and clears every package's .stamp_images_installed marker so the next
    # build repopulates it correctly (verified working) — but that means a
    # build's success now depends on that repopulation succeeding cleanly
    # for every affected package (linux, syslinux, grub2, shim, ...) on the
    # *following* run. Preferring to avoid that risk to future builds over
    # the disk-space savings. Run `./post-build-clean.sh` by hand when
    # space is actually needed.
    # ./post-build-clean.sh
    curl -H "Title: 🕹️ Batocera finished building" -d "Image building finished" $NOTIFYTOPIC
else
    curl -H "Title: 🕹️ Batocera build failed 😞" -d "Exit code $EC" $NOTIFYTOPIC
fi
