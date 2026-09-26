#!/bin/bash
#
# rebuild.sh — refresh the ES/configgen pipeline, then do a full image
# build for the given target, notifying $NOTIFYTOPIC on completion/failure.
#
# Usage: ./rebuild.sh [--batch] [--quick] [--no-fix-stale] [<target>]
#   <target>      buildroot target to build, e.g. zen3-focused (default)
#                 or x86_64-focused. Passed through to refresh-board-es.sh
#                 (as TARGET) and used for the `<target>-build` make target.
#   --quick, -q   faster refresh: skips wiping output/<target>/target and the
#                 in-repo data-package sweep (~3-5 min saved). Fine for
#                 iteration; use the default (full) for any image you will
#                 test or ship, so no leftovers from older builds slip in.
#   --batch, -b   pass BATCH_MODE=1 to the build (non-interactive Docker
#                 mode). Required when run with no attached TTY — e.g. via
#                 `nohup ./rebuild.sh &`, cron, or an agent's background
#                 shell — otherwise `docker run -t -i` fails with "cannot
#                 attach stdin to a TTY-enabled container because stdin is
#                 not a terminal". Omit for a normal interactive terminal
#                 run.
#   --check-docker  only run the Docker image self-check/auto-fix (below),
#                 then exit without building.
#   --no-fix-stale  only report stale per-package copies of watched packages
#                 (see "Stale per-package copies" below) and abort, instead of
#                 refreshing them (the default). --fix-stale is accepted as a
#                 no-op for older command lines.
#
# Docker image self-check (runs first, every time): the build image
# (batoceralinux/batocera.linux-build:latest) bakes docker/entry-point.sh in
# at image-build time, and `make` falls back to *pulling* the upstream Hub
# image whenever .ba-docker-image-available is missing — an image that lacks
# the HOME/gosu fix, which makes ccache silently write into the throwaway
# container instead of buildroot-ccache/ (builds "succeed", cache never
# grows; found 2026-09-20, see my-docs/AGENTS.md "ccache silently not
# persisting"). So before building we require the image to (1) exist,
# (2) contain an /opt/entry-point.sh identical to the repo's
# docker/entry-point.sh, and (3) actually resolve HOME=/home/batocera when
# run the way the build runs it. If any check fails we `make
# rebuild-docker-image` (a local build, never a pull) and re-check; if it
# still fails the run aborts with a notification rather than building with a
# broken cache. Skipped when DIRECT_BUILD is set. Docker overrides honoured:
# DOCKER, DOCKER_REPO, DOCKER_IMAGE_NAME (same defaults as docker/docker.mk).
#
# Stale per-package copies (found 2026-09-26): with per-package directories,
# every package that depends on retroarch (all the libretro cores) keeps its
# own copy of retroarch's installed files in output/<target>/per-package/
# <pkg>/target, taken when *that* package was last built. Rebuilding
# retroarch alone (e.g. after changing a patch) does not refresh those
# copies, and target assembly can let a stale copy win - the 2026-09-26
# image shipped the 2026-08-01 retroarch, without the patch 019 Vulkan
# light gun fix, even though per-package/retroarch had the fixed binary.
# So before building we compare every file each watched package installs
# (its build/<pkg>-<ver>/.files-list.txt) against the copies in the other
# per-package trees and copy the current files over any that differ - the
# same files buildroot would copy in if it rebuilt those packages, so this is
# the default (made default 2026-09-26; the owner's tree is always the right
# version). Each refreshed file is listed. --no-fix-stale aborts instead. After a successful build we also check that the
# image's /usr/bin/retroarch has the same code as per-package/retroarch.
# Watched packages: STALE_CHECK_PACKAGES (default "retroarch mesa3d"; mesa3d
# because the 2026-09-21 Radeon-only Mesa builds shipped a stale libgallium
# the same way).

set -a
source "$(dirname "$0")/topic.env"
set +a

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Prints why the image is unusable and returns 1; silent and 0 if it's good.
docker_image_problem() {
    local docker="${DOCKER:-docker}"
    local image="${DOCKER_REPO:-batoceralinux}/${DOCKER_IMAGE_NAME:-batocera.linux-build}"
    local home

    if ! "$docker" image inspect "$image" >/dev/null 2>&1; then
        echo "image $image is not present locally"
        return 1
    fi
    # --pull=never: a missing/odd image must never silently re-pull the Hub one
    if ! "$docker" run --rm --pull=never --entrypoint cat "$image" /opt/entry-point.sh 2>/dev/null \
            | cmp -s - "$REPO_ROOT/docker/entry-point.sh"; then
        echo "image's baked-in /opt/entry-point.sh differs from docker/entry-point.sh"
        return 1
    fi
    home="$("$docker" run --rm --pull=never -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
            "$image" sh -c 'echo "$HOME"' 2>/dev/null | tail -n1)"
    if [ "$home" != "/home/batocera" ]; then
        echo "build user resolves HOME='$home' inside the image (want /home/batocera) — ccache would not persist"
        return 1
    fi
    return 0
}

ensure_docker_image() {
    [ -n "${DIRECT_BUILD:-}" ] && return 0
    local why

    if why="$(docker_image_problem)"; then
        echo "==> Docker image OK (entry-point matches repo, HOME resolves to /home/batocera)"
        return 0
    fi
    echo "==> Docker image problem: $why"
    echo "==> Rebuilding it locally (make rebuild-docker-image) ..."
    if ! make -C "$REPO_ROOT" rebuild-docker-image; then
        echo "error: make rebuild-docker-image failed" >&2
        curl -H "Title: 🕹️ Batocera build aborted 😞" -d "Docker image rebuild failed" $NOTIFYTOPIC
        return 1
    fi
    if why="$(docker_image_problem)"; then
        echo "==> Docker image fixed"
        return 0
    fi
    echo "error: Docker image still bad after a local rebuild: $why" >&2
    curl -H "Title: 🕹️ Batocera build aborted 😞" -d "Docker image still bad after rebuild: $why" $NOTIFYTOPIC
    return 1
}

# Lists (or with $1=fix, refreshes) per-package copies of watched packages'
# installed files that differ from the package's own per-package tree.
# Prints one line per stale file and returns 1 if any were found (and not fixed).
check_stale_copies() {
    local mode="$1" out="$REPO_ROOT/output/$TARGET" pkg list f d stale=0 fixed=0
    [ -d "$out/per-package" ] || return 0
    for pkg in ${STALE_CHECK_PACKAGES:-retroarch mesa3d}; do
        list=""
        for f in "$out"/build/"$pkg"-*/.files-list.txt; do
            [ -f "$f" ] && [ "$(head -n1 "$f" | cut -d, -f1)" = "$pkg" ] && list="$f" && break
        done
        [ -n "$list" ] || continue
        while IFS= read -r f; do
            # skip development files that target-finalize strips from the
            # image anyway (headers, pkg-config, static/libtool libs, cmake)
            case "$f" in
                ./usr/include/*|*/pkgconfig/*|./usr/share/aclocal/*|./usr/lib/cmake/*|*.a|*.la) continue ;;
            esac
            [ -f "$out/per-package/$pkg/target/$f" ] || continue
            for d in "$out"/per-package/*/; do
                d="${d%/}"
                [ "${d##*/}" = "$pkg" ] && continue
                [ -f "$d/target/$f" ] || continue
                cmp -s "$out/per-package/$pkg/target/$f" "$d/target/$f" && continue
                if [ "$mode" = fix ]; then
                    echo "  refreshed: per-package/${d##*/}/target/${f#./} (from per-package/$pkg)"
                    cp -p "$out/per-package/$pkg/target/$f" "$d/target/$f"
                    fixed=$((fixed + 1))
                else
                    echo "  stale: per-package/${d##*/}/target/${f#./} (differs from per-package/$pkg)"
                    stale=$((stale + 1))
                fi
            done
        done < <(cut -d, -f2- "$list")
    done
    [ "$mode" = fix ] && [ $fixed -gt 0 ] && echo "==> Refreshed $fixed stale per-package file(s)"
    [ $stale -eq 0 ]
}

# After the build: does the image's retroarch have the same code as the one
# per-package/retroarch built? (target/ is stripped, so compare .text only.)
check_image_retroarch() {
    local out="$REPO_ROOT/output/$TARGET" objcopy a b
    objcopy="$(ls "$out"/host/bin/*-buildroot-linux-*-objcopy 2>/dev/null | head -n1)"
    [ -n "$objcopy" ] && [ -f "$out/target/usr/bin/retroarch" ] && \
        [ -f "$out/per-package/retroarch/target/usr/bin/retroarch" ] || return 0
    a="$("$objcopy" -O binary --only-section=.text "$out/target/usr/bin/retroarch" /dev/stdout | md5sum)"
    b="$("$objcopy" -O binary --only-section=.text "$out/per-package/retroarch/target/usr/bin/retroarch" /dev/stdout | md5sum)"
    [ "$a" = "$b" ]
}

BATCH_MODE="${BATCH_MODE:-}"
FIX_STALE=1
QUICK_FLAG=""
CHECK_DOCKER_ONLY=""
TARGET="${TARGET:-zen3-focused}"
for arg in "$@"; do
    case "$arg" in
        --batch|-b) BATCH_MODE=1 ;;
        --quick|-q) QUICK_FLAG=--quick ;;
        --check-docker) CHECK_DOCKER_ONLY=1 ;;
        --fix-stale) FIX_STALE=1 ;;
        --no-fix-stale) FIX_STALE="" ;;
        -h|--help)
            echo "Usage: $0 [--batch] [--quick] [--check-docker] [--no-fix-stale] [<target>]"
            echo "  <target>      buildroot target to build (default: zen3-focused)"
            echo "  --quick, -q   skip target wipe + data-package sweep (faster, not for release images)"
            echo "  --batch, -b   set BATCH_MODE=1 (required for non-interactive/no-TTY runs)"
            echo "  --check-docker  only verify/auto-fix the Docker build image, then exit"
            echo "  --no-fix-stale  abort on stale per-package copies of retroarch/mesa3d instead of refreshing them (default: refresh)"
            exit 0
            ;;
        -*)
            echo "error: unrecognized argument: $arg" >&2
            exit 1
            ;;
        *) TARGET="$arg" ;;
    esac
done

ensure_docker_image || exit 1
[ -n "$CHECK_DOCKER_ONLY" ] && exit 0

if [ -n "$FIX_STALE" ]; then
    check_stale_copies fix
fi
if ! check_stale_copies check; then
    echo "error: stale per-package copies found (see above) - the image would ship old files." >&2
    echo "       Re-run without --no-fix-stale to refresh them from the owning package." >&2
    curl -H "Title: 🕹️ Batocera build aborted 😞" -d "Stale per-package copies (run rebuild.sh without --no-fix-stale)" $NOTIFYTOPIC
    exit 1
fi

TARGET="$TARGET" ./refresh-board-es.sh $QUICK_FLAG

#PARALLEL_BUILD=y make "${TARGET}-build" BATCH_MODE="$BATCH_MODE" && ./update-usb.sh --auto
make "${TARGET}-build" BATCH_MODE="$BATCH_MODE"
EC=$?
if [ $EC -eq 0 ] && ! check_image_retroarch; then
    echo "error: the image's /usr/bin/retroarch differs from per-package/retroarch - a stale copy won." >&2
    curl -H "Title: 🕹️ Batocera image has a stale RetroArch 😞" -d "Image built but /usr/bin/retroarch is not the current build - don't install it" $NOTIFYTOPIC
    exit 1
fi

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
