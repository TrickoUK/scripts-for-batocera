#!/bin/bash
#
# rebuild.sh — refresh the ES/launcher pipeline, then do a full image
# build for the given target, notifying $NOTIFYTOPIC on completion/failure.
#
# Usage: ./rebuild.sh [--batch] [--quick] [--cores N] [--no-fix-stale] [<target>]
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
#   --cores N, -j N  compile with N parallel jobs instead of every core, to
#                 leave the rest free for other work (e.g. --cores 12 on a
#                 16-thread box keeps 4 free). Sets MAKE_JLEVEL (make -j and
#                 buildroot BR2_JLEVEL) and MAKE_LLEVEL (make -l load cap) to N
#                 for every make this script runs. Default: all cores (nproc).
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
# version). Each refreshed file is listed. --no-fix-stale aborts instead.
# After a successful build we also check that the image's /usr/bin/retroarch
# has the same code as per-package/retroarch.
# Watched packages: STALE_CHECK_PACKAGES (default "retroarch mesa3d"; mesa3d
# because the 2026-09-21 Radeon-only Mesa builds shipped a stale libgallium
# the same way).
#
# Stale kernel modules (found 2026-09-26): Buildroot does not rebuild
# out-of-tree kernel module packages when the kernel version changes. After
# the 7.1.5 -> 7.2.6 bump, xone, rtl8188eu, rtl8723bu, hid-t150,
# logitech-trueforce and ayaneo-platform were never rebuilt, so the image
# shipped their modules only under /lib/modules/7.1.5, which the 7.2.6
# kernel never loads (the drivers were effectively missing), plus the whole
# 7.1.5 module tree as dead weight. So before building we abort if any
# package's .files-list.txt installs into a lib/modules/<version> other than
# the configured kernel's release, and print the dirclean/rebuild commands.
# After the build, the check runs again against the regenerated .config (to
# catch a kernel bump in this very build) and also fails if target/lib/modules
# has any directory other than the current release. No --fix mode: the fix
# is a real rebuild of each package against the new kernel.
#
# Stale wine-x86 (found 2026-10-05): wine-x86 is a prebuilt tarball on the
# moving "44-dev" tag, and its dependents (wine-tkg, linuxloader) keep their
# own per-package snapshot of it. The single target-finalize rsync keeps the
# FIRST sorted copy, so a stale snapshot shipped 32-bit wine 11.13 against
# the 11.17 wineserver and every demul game died with "wine client error:0:
# version mismatch 961/956" (Lindbergh broke the same way earlier). When the
# target enables wine-x86 we run my-docs/tools/check-wine-x86.sh --pre before
# building (abort: republished tarball / stale snapshots, it prints which
# package needs a dirclean) and the full check after (target/ carries the
# current 32-bit wine). ~5 s each.
#
# Status file (added 2026-10-12): output/rebuild.status always holds this
# run's state, for watchers (agents) that can't rely on the ntfy push.
# Written atomically (tmp + mv) as one line:
#   RUNNING pid=<pid> target=<t> started=<iso time>
#   OK      pid=<pid> target=<t> started=<...> finished=<...> exit=0
#   FAILED  pid=<pid> target=<t> started=<...> finished=<...> exit=<n> reason=<text>
# An EXIT trap writes the final line on every exit path (aborts, failed make,
# post-build image checks, Ctrl-C/SIGTERM/SIGHUP). Only SIGKILL or a power
# cut can leave it at RUNNING, so a watcher should treat "RUNNING but
# `kill -0 <pid>` fails" as died-without-status. Wait for completion with:
#   until ! grep -q '^RUNNING' output/rebuild.status; do sleep 30; done

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

# Kernel release the target is configured for: the built kernel's own
# kernel.release when it matches .config, else the .config version.
kernel_release() {
    local out="$REPO_ROOT/output/$TARGET" ver rel
    ver="$(sed -n 's/^BR2_LINUX_KERNEL_VERSION="\(.*\)"$/\1/p' "$out/.config" 2>/dev/null)"
    [ -n "$ver" ] || return 1
    rel="$(cat "$out/build/linux-$ver/include/config/kernel.release" 2>/dev/null)"
    echo "${rel:-$ver}"
}

# Lists packages that installed kernel modules for a kernel other than the
# configured one (and, with $1=image, stray target/lib/modules/<version>
# dirs). Prints one line per problem plus fix commands; returns 1 if any.
check_stale_kernel_modules() {
    local mode="$1" out="$REPO_ROOT/output/$TARGET" rel f pkg vers d bad=0 pkgs=""
    rel="$(kernel_release)" || return 0
    for f in "$out"/build/*/.files-list.txt; do
        [ -f "$f" ] || continue
        vers="$(cut -d, -f2- "$f" | sed -n 's#^\./lib/modules/\([^/]*\)/.*#\1#p' | sort -u | grep -vx "$rel")"
        [ -n "$vers" ] || continue
        pkg="$(head -n1 "$f" | cut -d, -f1)"
        echo "  stale kernel modules: $pkg installs for $(echo $vers) (kernel is $rel)"
        pkgs="$pkgs $pkg"
        bad=1
    done
    if [ "$mode" = image ] && [ -d "$out/target/lib/modules" ]; then
        for d in "$out"/target/lib/modules/*/; do
            d="$(basename "$d")"
            [ "$d" = "$rel" ] && continue
            echo "  stray module dir in image: target/lib/modules/$d (kernel is $rel)"
            bad=1
        done
    fi
    if [ -n "$pkgs" ]; then
        echo "  fix: rebuild each against the current kernel (separate calls - one CMD only dircleans):"
        for pkg in $pkgs; do
            echo "    make $TARGET-build CMD=$pkg-dirclean BATCH_MODE=1 && make $TARGET-build CMD=$pkg BATCH_MODE=1"
        done
    fi
    [ $bad -eq 1 ] && echo "  then remove leftover old-version dirs: output/$TARGET/per-package/*/target/lib/modules/<old> and target/lib/modules/<old>"
    [ $bad -eq 0 ]
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

# Runs my-docs/tools/check-wine-x86.sh (args passed through) when the target
# builds wine-x86; returns 0 when it doesn't.
check_wine_x86() {
    grep -qx 'BR2_PACKAGE_WINE_X86=y' "$REPO_ROOT/output/$TARGET/.config" 2>/dev/null || return 0
    TARGET="$TARGET" "$REPO_ROOT/my-docs/tools/check-wine-x86.sh" "$@"
}

BATCH_MODE="${BATCH_MODE:-}"
FIX_STALE=1
QUICK_FLAG=""
CHECK_DOCKER_ONLY=""
CORES=""
TARGET="${TARGET:-zen3-focused}"
while [ $# -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in
        --cores|-j)
            if [ $# -eq 0 ]; then
                echo "error: $arg needs a number of cores" >&2
                exit 1
            fi
            CORES="$1"
            shift
            ;;
        --cores=*|-j=*) CORES="${arg#*=}" ;;
        --batch|-b) BATCH_MODE=1 ;;
        --quick|-q) QUICK_FLAG=--quick ;;
        --check-docker) CHECK_DOCKER_ONLY=1 ;;
        --fix-stale) FIX_STALE=1 ;;
        --no-fix-stale) FIX_STALE="" ;;
        -h|--help)
            echo "Usage: $0 [--batch] [--quick] [--cores N] [--check-docker] [--no-fix-stale] [<target>]"
            echo "  <target>      buildroot target to build (default: zen3-focused)"
            echo "  --quick, -q   skip target wipe + data-package sweep (faster, not for release images)"
            echo "  --batch, -b   set BATCH_MODE=1 (required for non-interactive/no-TTY runs)"
            echo "  --cores N, -j N  compile with N parallel jobs (default: all cores), to keep some free"
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
    # the Makefile takes MAKE_JLEVEL/MAKE_LLEVEL from the environment (?=)
    export MAKE_JLEVEL="$CORES" MAKE_LLEVEL="$CORES"
    echo "Using $CORES of $TOTAL_CORES cores for compilation"
fi

STATUS_FILE="$REPO_ROOT/output/rebuild.status"
STATUS_STARTED="$(date -Iseconds)"
STATUS_REASON=""
write_status() {
    mkdir -p "$(dirname "$STATUS_FILE")"
    echo "$1 pid=$$ target=$TARGET started=$STATUS_STARTED${2:+ $2}" > "$STATUS_FILE.tmp" &&
        mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
}
on_exit() {
    local ec=$?
    if [ $ec -eq 0 ]; then
        write_status OK "finished=$(date -Iseconds) exit=0"
    else
        write_status FAILED "finished=$(date -Iseconds) exit=$ec reason=${STATUS_REASON:-unknown}"
    fi
}
write_status RUNNING
trap on_exit EXIT
trap 'STATUS_REASON="interrupted (SIGINT)"; exit 130' INT
trap 'STATUS_REASON="terminated (SIGTERM)"; exit 143' TERM
trap 'STATUS_REASON="hangup (SIGHUP)"; exit 129' HUP

STATUS_REASON="docker image check failed"
ensure_docker_image || exit 1
[ -n "$CHECK_DOCKER_ONLY" ] && exit 0
STATUS_REASON=""

if [ -n "$FIX_STALE" ]; then
    check_stale_copies fix
fi
if ! check_stale_copies check; then
    echo "error: stale per-package copies found (see above) - the image would ship old files." >&2
    echo "       Re-run without --no-fix-stale to refresh them from the owning package." >&2
    curl -H "Title: 🕹️ Batocera build aborted 😞" -d "Stale per-package copies (run rebuild.sh without --no-fix-stale)" $NOTIFYTOPIC
    STATUS_REASON="aborted: stale per-package copies"
    exit 1
fi

if ! check_stale_kernel_modules; then
    echo "error: kernel module packages built for an old kernel (see above) - the image would ship drivers the kernel can't load." >&2
    curl -H "Title: 🕹️ Batocera build aborted 😞" -d "Kernel module packages built for an old kernel - see rebuild log for fix commands" $NOTIFYTOPIC
    STATUS_REASON="aborted: kernel module packages built for an old kernel"
    exit 1
fi

if ! check_wine_x86 --pre; then
    echo "error: wine-x86 is stale (see FAIL lines above) - the image would ship mismatched 32-bit wine." >&2
    curl -H "Title: 🕹️ Batocera build aborted 😞" -d "Stale wine-x86 (tarball or wine-tkg/linuxloader snapshot) - see rebuild log" $NOTIFYTOPIC
    STATUS_REASON="aborted: stale wine-x86"
    exit 1
fi

STATUS_REASON="refresh-board-es.sh failed"
TARGET="$TARGET" ./refresh-board-es.sh $QUICK_FLAG || exit 1
STATUS_REASON=""

#PARALLEL_BUILD=y make "${TARGET}-build" BATCH_MODE="$BATCH_MODE" && ./update-usb.sh --auto
make "${TARGET}-build" BATCH_MODE="$BATCH_MODE"
EC=$?
if [ $EC -eq 0 ] && ! check_image_retroarch; then
    echo "error: the image's /usr/bin/retroarch differs from per-package/retroarch - a stale copy won." >&2
    curl -H "Title: 🕹️ Batocera image has a stale RetroArch 😞" -d "Image built but /usr/bin/retroarch is not the current build - don't install it" $NOTIFYTOPIC
    STATUS_REASON="image built but has a stale retroarch - don't install it"
    exit 1
fi
if [ $EC -eq 0 ] && ! check_stale_kernel_modules image; then
    echo "error: the image has kernel modules for an old kernel (see above)." >&2
    curl -H "Title: 🕹️ Batocera image has stale kernel modules 😞" -d "Image built but some drivers are for an old kernel - see rebuild log" $NOTIFYTOPIC
    STATUS_REASON="image built but has stale kernel modules - don't install it"
    exit 1
fi
if [ $EC -eq 0 ] && ! check_wine_x86; then
    echo "error: the image's wine-x86 payload is stale (see FAIL lines above)." >&2
    curl -H "Title: 🕹️ Batocera image has stale wine-x86 😞" -d "Image built but 32-bit wine/Lindbergh files are stale - don't install it" $NOTIFYTOPIC
    STATUS_REASON="image built but has stale wine-x86 - don't install it"
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
    STATUS_REASON="make ${TARGET}-build failed"
fi
exit $EC
