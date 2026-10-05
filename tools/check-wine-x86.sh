#!/bin/bash
#
# check-wine-x86.sh — run after every origin/master merge (and before trusting
# a build that should carry Lindbergh / any 32-bit wine-x86 payload).
#
# Why (2026-10-05): wine-x86 is a prebuilt tarball on a MOVING release tag
# (WINE_X86_VERSION = $(BATOCERA_SYSTEM_VERSION) = "44-dev"). Upstream
# republishes it under the same file name, so Buildroot never re-downloads it,
# and a re-downloaded tarball is never re-extracted either (same version =
# stamps satisfied). The zen3 build kept shipping an Aug 1 extraction with the
# old /usr/bin/lindbergh layout after upstream renamed it to linuxloader
# (#16517, Sep 18) -> every Lindbergh launch died on a missing
# /usr/bin/linuxloader/linuxloader.ini.
#
# Checks (exit 1 if any fails):
#   1. local dl tarball == the one currently published upstream (size)
#   2. the build dir was extracted from the current dl tarball (stamp newer)
#   3. the tarball has the files batocera_launch_linuxloader reads
#      (its _SOURCE_DIR + linuxloader.ini/controls.ini)
#   4. the built target/ has them too (if a target/ exists)
#
# Fix when 1/2 fail: move dl/wine-x86/wine-x86-44-dev.tar.lzma aside, then
#   make <t>-build BATCH_MODE=1 CMD="wine-x86-dirclean"
# and rebuild (the build re-downloads it).
#
#   5. no other per-package tree (wine-tkg, linuxloader) holds an older
#      wine-x86 snapshot
#   6. the built target/ carries the current 32-bit wine
#
# Usage: my-docs/tools/check-wine-x86.sh [--pre]   (TARGET=<t>, default zen3-focused)
#   --pre  before a build: skip the target/ checks (4, 6) — target/ is about
#          to be rebuilt. rebuild.sh runs it with --pre before building and
#          without after.
# Offline (upstream size unreadable) is a warning, not a failure.
set -u
PRE=""
[ "${1:-}" = --pre ] && PRE=1
cd "$(dirname "$0")/../.." || exit 1
TARGET="${TARGET:-zen3-focused}"
VER=$(sed -n 's/^BATOCERA_SYSTEM_VERSION = //p' package/batocera/core/batocera-system/batocera-system.mk)
NAME="wine-x86-${VER}.tar.lzma"
DL="dl/wine-x86/${NAME}"
URL="https://github.com/batocera-linux/wine-x86/releases/download/${VER}/${NAME}"
BUILD="output/${TARGET}/build/wine-x86-${VER}"
SRC_DIR=$(sed -n "s/^_SOURCE_DIR: Final = Path('\/\(.*\)')$/\1/p" \
    python-src/batocera-launch-linuxloader/batocera_launch_linuxloader/emulator.py)
bad=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; bad=1; }

# 1. upstream republished?
remote=$(curl -sIL "$URL" | tr -d '\r' | awk 'tolower($1)=="content-length:"{n=$2} END{print n}')
if [ ! -f "$DL" ]; then
    echo "info $DL not downloaded yet (next build fetches the current one)"
elif [ -z "$remote" ]; then
    echo "warn could not read upstream size for $URL (offline?) - check 1 skipped"
elif [ "$remote" = "$(stat -c %s "$DL")" ]; then
    ok "dl tarball matches upstream ($remote bytes)"
else
    fail "dl tarball is $(stat -c %s "$DL") bytes, upstream now $remote — upstream republished ${VER}"
fi

# 2. extracted from the current dl tarball?
if [ -f "$BUILD/.stamp_extracted" ] && [ -f "$DL" ]; then
    if [ "$BUILD/.stamp_extracted" -nt "$DL" ]; then
        ok "build dir extracted after the dl tarball was fetched"
    else
        fail "$BUILD was extracted $(date -r "$BUILD/.stamp_extracted" +%F) from an older tarball (dl file $(date -r "$DL" +%F)) — needs wine-x86-dirclean"
    fi
else
    echo "info no extracted wine-x86 build dir (next build extracts fresh)"
fi

# 3. tarball carries what the launcher reads
if [ -f "$DL" ] && [ -n "$SRC_DIR" ]; then
    list=$(tar --lzma -tf "$DL" 2>/dev/null)
    for f in linuxloader.ini controls.ini; do
        grep -qx "${SRC_DIR}/${f}" <<<"$list" && ok "tarball has /${SRC_DIR}/${f}" \
            || fail "tarball lacks /${SRC_DIR}/${f} (launcher _SOURCE_DIR changed again?)"
    done
fi

# 4. built target carries it
T="output/${TARGET}/target"
if [ -z "$PRE" ] && [ -d "$T" ] && [ -n "$SRC_DIR" ]; then
    [ -f "$T/${SRC_DIR}/linuxloader.ini" ] && ok "target/ has /${SRC_DIR}/linuxloader.ini" \
        || fail "target/ lacks /${SRC_DIR}/linuxloader.ini (stale wine-x86 extraction or not built yet)"
fi

# 5./6. (2026-10-05, demul "wine client error: version mismatch 961/956"):
# dependents of wine-x86 (wine-tkg, linuxloader) keep a per-package snapshot of
# the wine-x86 files from when THEY were built. A wine-x86 dirclean does not
# refresh those, and the single target-finalize rsync keeps the FIRST sorted
# copy (linuxloader < wine-tkg < wine-x86), so the image shipped 11.13 32-bit
# wine against the 11.17 wineserver. Sentinels: the 32-bit wine version string
# (survives stripping) and an unstripped PE file.
PP="output/${TARGET}/per-package"
UNIX=usr/wine/wine-tkg/lib/wine/i386-unix/ntdll.so
PE=usr/wine/wine-tkg/lib/wine/i386-windows/ntdll.dll
wver() { grep -ao 'wine-[0-9][0-9.]*\.r[0-9]*\.g[0-9a-f]*' "$1" 2>/dev/null | head -n1; }
if [ -f "$PP/wine-x86/target/$UNIX" ]; then
    want=$(wver "$PP/wine-x86/target/$UNIX")
    for d in "$PP"/*/; do
        d="${d%/}"; p="${d##*/}"
        [ "$p" = wine-x86 ] && continue
        [ -f "$d/target/$UNIX" ] || continue
        if [ "$(wver "$d/target/$UNIX")" = "$want" ] && cmp -s "$PP/wine-x86/target/$PE" "$d/target/$PE"; then
            ok "per-package/$p wine-x86 snapshot is current ($want)"
        else
            fail "per-package/$p holds a stale wine-x86 snapshot ($(wver "$d/target/$UNIX"), want $want) — needs $p-dirclean"
        fi
    done
    if [ -z "$PRE" ] && [ -f "$T/$UNIX" ]; then
        if [ "$(wver "$T/$UNIX")" = "$want" ] && cmp -s "$PP/wine-x86/target/$PE" "$T/$PE"; then
            ok "target/ 32-bit wine is current ($want)"
        else
            fail "target/ 32-bit wine is $(wver "$T/$UNIX"), want $want — delete target/ copies of wine-x86's files after fixing per-package (rsync -u keeps the newer stripped copies)"
        fi
    fi
fi

echo "WINE-X86 RESULT: $([ $bad = 0 ] && echo OK || echo FAIL)"
exit $bad
