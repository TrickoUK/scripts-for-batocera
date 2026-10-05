#!/bin/bash
#
# post-build-clean.sh — free disk space after a build by deleting everything
# under output/<target>/images/ except the actual flashable output.
#
# board/batocera/scripts/post-image-script.sh:37-41 already unconditionally
# `rm -rf`s output/<target>/images/batocera/ and regenerates it from scratch
# on every build that reaches the image-assembly stage — nothing under
# images/ is incrementally reused between builds (unlike build/, per-package/,
# and ccache, which genuinely are). So everything in output/<target>/images/
# *except* the final packaged boot.tar.xz/.img.gz/checksums under
# images/batocera/images/<build-type>/ (what update-usb.sh and a real flash
# actually consume) is pure dead weight the moment a build finishes — kept
# only as byproducts of the last run (bzImage, rootfs.squashfs, the unpacked
# boot_<build-type>/ tree used to build the tarball, etc.), several GB per
# build, and of no use for the next one.
#
# This does NOT touch build/, per-package/, staging/, host/, target/, or
# buildroot-ccache/ — those are Buildroot's real incremental-build state and
# deleting them would force a from-scratch rebuild. Only images/ (the final
# assembly output) is in scope.
#
# Gotcha this script must account for: several packages (linux, syslinux,
# grub2, shim, batocera-emulationstation, batocera-system, ...) gate their
# one-time "copy my output into images/" step behind a per-package
# output/<target>/build/<pkg>/.stamp_images_installed marker. Buildroot never
# re-checks whether the file that step produced still exists — only whether
# the stamp exists — so wiping images/ without also clearing those stamps
# means the *next* build silently skips re-populating images/ for every such
# package (missing bzImage, missing bootloader files, etc.), even though the
# stamp says "done". So this script also clears every
# .stamp_images_installed it finds, forcing Buildroot to redo that step next
# build.
#
# Usage: ./post-build-clean.sh [--dry-run]
#   TARGET=<buildroot target>   (env var, default: zen3-focused)

set -euo pipefail

TARGET="${TARGET:-zen3-focused}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            echo "Usage: $0 [--dry-run]"
            echo "  TARGET=<buildroot target>   env var, default: zen3-focused"
            exit 0
            ;;
        *)
            echo "error: unrecognized argument: $arg" >&2
            exit 1
            ;;
    esac
done

IMAGES_DIR="${REPO_ROOT}/output/${TARGET}/images"
KEEP_SRC="${IMAGES_DIR}/batocera/images"
BUILD_DIR="${REPO_ROOT}/output/${TARGET}/build"

if [ ! -d "$IMAGES_DIR" ]; then
    echo "error: ${IMAGES_DIR} doesn't exist — nothing to clean" >&2
    exit 1
fi

if [ ! -d "$KEEP_SRC" ] || [ -z "$(find "$KEEP_SRC" -mindepth 1 -print -quit)" ]; then
    echo "error: ${KEEP_SRC} missing or empty — refusing to wipe ${IMAGES_DIR} with nothing worth keeping" >&2
    echo "  (run a full '${TARGET}-build' through to completion first)" >&2
    exit 1
fi

# --- refuse to run against a target a build container is actively using ----

for cid in $(docker ps -q 2>/dev/null); do
    if docker inspect --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$cid" 2>/dev/null \
        | grep -qxF "${REPO_ROOT}/output/${TARGET}"; then
        echo "error: a running container (${cid}) has output/${TARGET} mounted — refusing to clean mid-build" >&2
        exit 1
    fi
done

# --- move the flashable output aside, wipe images/, put it back -----------

BEFORE_BYTES=$(du -sb "$IMAGES_DIR" | cut -f1)

STAGE=$(mktemp -d "${REPO_ROOT}/.post-build-clean.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

mv "$KEEP_SRC" "$STAGE/images"

echo "Keeping (flashable output):"
find "$STAGE/images" -mindepth 2 -type f -printf '%s %p\n' \
    | while read -r size path; do
        echo "  images/batocera/images/${path#"$STAGE/images/"} (${size} bytes)"
    done

# --- find every package that gates its images/ copy behind a stamp --------
# (see the file-header gotcha note) so we can clear them below and force
# Buildroot to redo that step next build, instead of trusting a stamp that
# now lies about images/ still having what it produced.
mapfile -t IMAGE_STAMPS < <(find "$BUILD_DIR" -mindepth 2 -maxdepth 2 -name '.stamp_images_installed' 2>/dev/null | sort)

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "--dry-run: would delete everything else under ${IMAGES_DIR} ($(du -sh "$IMAGES_DIR" | cut -f1) total)"
    echo
    if [ "${#IMAGE_STAMPS[@]}" -eq 0 ]; then
        echo "--dry-run: no .stamp_images_installed markers found under ${BUILD_DIR}"
    else
        echo "--dry-run: would clear ${#IMAGE_STAMPS[@]} .stamp_images_installed marker(s) so their package(s) re-populate images/ next build:"
        for stamp in "${IMAGE_STAMPS[@]}"; do
            echo "  ${stamp#"${BUILD_DIR}/"}"
        done
    fi
    mv "$STAGE/images" "$KEEP_SRC"
    exit 0
fi

rm -rf "$IMAGES_DIR"
mkdir -p "$(dirname "$KEEP_SRC")"
mv "$STAGE/images" "$KEEP_SRC"

AFTER_BYTES=$(du -sb "$IMAGES_DIR" | cut -f1)
FREED_MB=$(( (BEFORE_BYTES - AFTER_BYTES) / 1024 / 1024 ))
echo
echo "Freed ${FREED_MB}MB — ${IMAGES_DIR} is now $(du -sh "$IMAGES_DIR" | cut -f1)"

if [ "${#IMAGE_STAMPS[@]}" -gt 0 ]; then
    rm -f "${IMAGE_STAMPS[@]}"
    echo
    echo "Cleared ${#IMAGE_STAMPS[@]} .stamp_images_installed marker(s) so their package(s) re-populate images/ next build:"
    for stamp in "${IMAGE_STAMPS[@]}"; do
        echo "  ${stamp#"${BUILD_DIR}/"}"
    done
fi
