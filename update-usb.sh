#!/bin/bash
#
# update-usb.sh — deploy a freshly built batocera.linux image straight onto
# an already-installed USB stick, so a rebuild can be tested with a single
# reboot instead of a full reflash or booting the old build to self-update.
#
# Reproduces the same steps batocera's own updater
# (package/batocera/core/batocera-scripts/scripts/batocera-upgrade,
# do_update()) performs on a live system, run instead from the host against
# the boot partition of a mounted USB stick. Never touches the SHARE
# (userdata) partition.
#
# This only STAGES the update (boot/batocera.update, boot/rufomaculata.update,
# boot/boot.stale) — same as do_update() does on a live system. The actual
# swap into place and stale-file cleanup happen in the target device's own
# initramfs (package/batocera/boot/batocera-initramfs/init) on its NEXT boot.
#
# If a previously staged update was never applied (target wasn't booted since
# the last run), it's discarded before staging the new one — it's just dead
# weight at that point, not a rollback path worth keeping.
#
# Usage: ./update-usb.sh [mountpoint] [--dry-run]
#   TARGET=<buildroot target>   (env var, default: x86_64-arcade)

set -euo pipefail

TARGET="${TARGET:-x86_64-arcade}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
MOUNTPOINT=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            echo "Usage: $0 [mountpoint] [--dry-run]"
            echo "  TARGET=<buildroot target>   env var, default: x86_64-arcade"
            exit 0
            ;;
        *) MOUNTPOINT="$arg" ;;
    esac
done

# --- locate the build output ---------------------------------------------

BOOT_TARBALL_CANDIDATES=$(find "${REPO_ROOT}/output/${TARGET}/images/batocera/images" \
    -mindepth 2 -maxdepth 2 -name boot.tar.xz 2>/dev/null)
if [ -z "$BOOT_TARBALL_CANDIDATES" ]; then
    echo "error: no boot.tar.xz found under output/${TARGET}/images/batocera/images/ — run a build first" >&2
    exit 1
fi
if [ "$(echo "$BOOT_TARBALL_CANDIDATES" | wc -l)" -gt 1 ]; then
    echo "error: multiple boot.tar.xz candidates found under output/${TARGET}/images/batocera/images/ — refusing to guess:" >&2
    echo "$BOOT_TARBALL_CANDIDATES" | sed 's/^/  - /' >&2
    exit 1
fi
BOOT_TARBALL="$BOOT_TARBALL_CANDIDATES"

# --- verify the build output before trusting it ---------------------------

MD5_FILE="${BOOT_TARBALL}.md5"
if [ ! -f "$MD5_FILE" ]; then
    echo "error: ${MD5_FILE} missing — can't verify build output, refusing to proceed" >&2
    exit 1
fi
EXPECTED_MD5=$(cat "$MD5_FILE")
ACTUAL_MD5=$(md5sum "$BOOT_TARBALL" | awk '{print $1}')
if [ "$EXPECTED_MD5" != "$ACTUAL_MD5" ]; then
    echo "error: checksum mismatch on ${BOOT_TARBALL}" >&2
    echo "  expected: ${EXPECTED_MD5}" >&2
    echo "  actual:   ${ACTUAL_MD5}" >&2
    echo "build output looks corrupt/truncated — rebuild before retrying" >&2
    exit 1
fi
echo "checksum OK: ${BOOT_TARBALL}"

# --- resolve and sanity-check the target mountpoint ------------------------

if [ -z "$MOUNTPOINT" ]; then
    MOUNTPOINT=$(findmnt -rn -S LABEL=BATOCERA -o TARGET 2>/dev/null | head -1)
fi
if [ -z "$MOUNTPOINT" ]; then
    echo "error: no mounted BATOCERA partition found or specified" >&2
    echo "usage: $0 [mountpoint] [--dry-run]" >&2
    exit 1
fi
if [ ! -f "${MOUNTPOINT}/boot/batocera.board" ]; then
    echo "error: ${MOUNTPOINT} doesn't look like a batocera boot partition (no boot/batocera.board)" >&2
    exit 1
fi

# --- validate board/arch, same as batocera-upgrade's validate_arch() -------

TARBALL_BOARD=$(tar -xJf "$BOOT_TARBALL" boot/batocera.board -O 2>/dev/null)
TARGET_BOARD=$(cat "${MOUNTPOINT}/boot/batocera.board")
if [ -z "$TARBALL_BOARD" ]; then
    echo "error: couldn't read boot/batocera.board from ${BOOT_TARBALL}" >&2
    exit 1
fi
if [ "$TARBALL_BOARD" != "$TARGET_BOARD" ]; then
    if { [ "$TARBALL_BOARD" = "x86_64" ] && [ "$TARGET_BOARD" = "x86-64-v3" ]; } || \
       { [ "$TARBALL_BOARD" = "x86-64-v3" ] && [ "$TARGET_BOARD" = "x86_64" ]; }; then
        echo "Migrating ${TARGET_BOARD} to ${TARBALL_BOARD}"
    else
        echo "error: board mismatch — ${MOUNTPOINT} is ${TARGET_BOARD}, this build is ${TARBALL_BOARD}" >&2
        exit 1
    fi
fi

# --- discard any unconsumed staged update from a previous run --------------
# boot/*.update only exists if the target hasn't booted since it was last
# staged — a real boot always renames it away via batocera-initramfs/init
# (init:64-78). Leaving it around just wastes space for no benefit: this
# run's tar is about to write a fresh .update of its own anyway.

STALE_UPDATE_BYTES=0
STALE_UPDATE_PATHS=()
for img in batocera rufomaculata; do
    f="${MOUNTPOINT}/boot/${img}.update"
    if [ -f "$f" ]; then
        STALE_UPDATE_PATHS+=("$f")
        STALE_UPDATE_BYTES=$((STALE_UPDATE_BYTES + $(stat -c%s "$f")))
    fi
done

if [ "${#STALE_UPDATE_PATHS[@]}" -gt 0 ]; then
    echo "Found staged update(s) the target hasn't booted yet (never applied, safe to discard):"
    printf '  - %s\n' "${STALE_UPDATE_PATHS[@]}"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "--dry-run: would delete these before copying the new build."
    else
        rm -f "${STALE_UPDATE_PATHS[@]}"
        sync
        echo "Deleted stale staged update(s)."
    fi
    echo
fi

# --- verify enough free space, same as batocera-upgrade's check_freespace --

UNCOMPRESSED_MB=$(($(xz --robot -l "$BOOT_TARBALL" | tail -1 | awk '{print $5}') / 1024 / 1024))
FREE_MB=$(df -m "$MOUNTPOINT" | tail -1 | awk '{print $4}')
if [ "$DRY_RUN" -eq 1 ] && [ "$STALE_UPDATE_BYTES" -gt 0 ]; then
    # not actually deleted yet in dry-run, so credit the space back manually
    FREE_MB=$((FREE_MB + STALE_UPDATE_BYTES / 1024 / 1024))
fi
if [ "$((UNCOMPRESSED_MB + 10))" -gt "$FREE_MB" ]; then
    echo "error: not enough space on ${MOUNTPOINT} to extract this build" >&2
    echo "  required: $((UNCOMPRESSED_MB + 10))MB | available: ${FREE_MB}MB" >&2
    exit 1
fi

# --- compute the stale-file list (files on the device that won't exist ----
# --- after extraction), same exclusions as upstream do_update() -----------

STALE_EXCLUDE_RE='^(boot/batocera|boot/batocera\.update|boot/rufomaculata|boot/rufomaculata\.update|boot/overlay|boot/overlay\.old|[^/]+\.upgrade|boot\.stale|.*ldlinux.*|boot/spi-flash\.log)$'

BEFORE_LIST=$(find "$MOUNTPOINT" -mindepth 1 -type f | sed "s|^${MOUNTPOINT}/||" | grep -vE "$STALE_EXCLUDE_RE" | sort)
TARBALL_LIST=$(tar -tJf "$BOOT_TARBALL" | sed -e 's|^\./||' -e 's|/$||' | sort -u)
STALE_LIST=$(comm -23 <(echo "$BEFORE_LIST") <(echo "$TARBALL_LIST"))

echo
echo "Source:      ${BOOT_TARBALL} ($(du -h "$BOOT_TARBALL" | cut -f1), $(date -r "$BOOT_TARBALL" '+%Y-%m-%d %H:%M'))"
echo "Target:      ${MOUNTPOINT}"
if [ -n "$STALE_LIST" ]; then
    echo "Stale files that will be marked for removal (applied by the target on its next boot):"
    echo "$STALE_LIST" | sed 's/^/  - /'
else
    echo "No stale files to remove."
fi
echo

if [ "$DRY_RUN" -eq 1 ]; then
    echo "--dry-run: no changes made."
    exit 0
fi

read -r -p "Overwrite system files on ${MOUNTPOINT} with this build? [y/N] " CONFIRM
case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
esac

# --- back up local settings, extract, restore ------------------------------

BOOT_CONF_BACKUP=""
if [ -f "${MOUNTPOINT}/batocera-boot.conf" ]; then
    BOOT_CONF_BACKUP=$(mktemp)
    cp "${MOUNTPOINT}/batocera-boot.conf" "$BOOT_CONF_BACKUP"
fi

echo "Extracting ${BOOT_TARBALL} onto ${MOUNTPOINT} ..."
tar -xJf "$BOOT_TARBALL" -C "$MOUNTPOINT" --no-same-owner

# --- verify the staged .update images actually landed intact ---------------
# (this is what the target's initramfs swaps into place on its next boot —
# a silent failure here means the reboot will just keep booting the old
# system, with no other symptom)

UPDATE_MEMBERS=$(echo "$TARBALL_LIST" | grep -E '\.update$' || true)
if [ -n "$UPDATE_MEMBERS" ]; then
    echo "Verifying staged update images ..."
    while IFS= read -r member; do
        [ -z "$member" ] && continue
        EXPECTED_SIZE=$(tar -tvJf "$BOOT_TARBALL" -- "$member" 2>/dev/null | awk '{print $3}')
        if [ -z "$EXPECTED_SIZE" ]; then
            echo "error: couldn't read expected size for ${member} from ${BOOT_TARBALL}" >&2
            exit 1
        fi
        if [ ! -f "${MOUNTPOINT}/${member}" ]; then
            echo "error: expected staged file ${member} is missing on ${MOUNTPOINT} after extraction" >&2
            exit 1
        fi
        ACTUAL_SIZE=$(stat -c%s "${MOUNTPOINT}/${member}")
        if [ "$EXPECTED_SIZE" != "$ACTUAL_SIZE" ]; then
            echo "error: ${member} size mismatch after extraction (expected ${EXPECTED_SIZE}, got ${ACTUAL_SIZE})" >&2
            exit 1
        fi
        echo "  OK: ${member} (${ACTUAL_SIZE} bytes)"
    done <<< "$UPDATE_MEMBERS"
fi

# --- stage the stale-file list for the target's initramfs to apply ---------
# (do_update() never deletes these itself either — batocera-initramfs/init
# removes them on next boot, atomically alongside the .update image swap)

if [ -n "$STALE_LIST" ]; then
    echo "Writing boot.stale for next-boot cleanup ..."
    echo "$STALE_LIST" > "${MOUNTPOINT}/boot.stale"
else
    rm -f "${MOUNTPOINT}/boot.stale"
fi

if [ -n "$BOOT_CONF_BACKUP" ]; then
    cp "$BOOT_CONF_BACKUP" "${MOUNTPOINT}/batocera-boot.conf"
    rm -f "$BOOT_CONF_BACKUP"
fi

sync

# --- unmount so the write is durable before the drive is physically pulled -

DEVICE=$(findmnt -no SOURCE "$MOUNTPOINT")
PARENT_DISK=$(lsblk -no PKNAME "$DEVICE" 2>/dev/null)

echo "Unmounting ${MOUNTPOINT} ..."
umount "$MOUNTPOINT"

if [ -n "$PARENT_DISK" ]; then
    OTHER_MOUNTS=$(lsblk -no NAME,MOUNTPOINT "/dev/${PARENT_DISK}" | awk '$2 != "" {print}')
    if [ -n "$OTHER_MOUNTS" ]; then
        echo
        echo "Warning: other partitions on the same drive are still mounted:"
        echo "$OTHER_MOUNTS" | sed 's/^/  /'
        echo "Unmount those too before removing the drive."
    fi
fi

echo
echo "Done. ${MOUNTPOINT} is unmounted — safe to remove the drive."
echo "Update is staged only; the swap happens on the target device's next boot."
