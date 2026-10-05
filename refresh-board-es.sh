#!/bin/bash
#
# refresh-board-es.sh — combination of refresh-board.sh + refresh-es.sh.
#
# Run this after changing a board .config option (e.g. adding/removing a
# BR2_PACKAGE_* line in configs/batocera-zen3-focused.board) AND the change
# also needs the EmulationStation / configgen option pipeline rebuilt to be
# visible (e.g. the new package is referenced from es_systems.yml,
# libretroOptions.py, a *.core.yml, or es_features.yml).
#
# Steps:
#   1. Regenerate the defconfig and .config from the board file
#      (refresh-board.sh's job).
#   2. Dirclean the full ES/configgen pipeline (refresh-es.sh's package list,
#      which is a superset of refresh-board.sh's lone batocera-es-system
#      dirclean) so the NEXT build — typically a full image build you kick
#      off yourself afterwards — rebuilds all of them fresh instead of
#      reusing stale output:
#        - batocera-launch + batocera-launch-* (runtime launcher/option code
#                                      and the per-arch default core/emulator
#                                      files; batocera-configgen was removed
#                                      upstream 2026-10-04)
#        - host-batocera-es-system   (host codegen tool: yml -> es_systems.cfg
#                                      / es_features.cfg)
#        - batocera-es-system        (runs the host tool, installs generated
#                                      cfg files to the target)
#        - batocera-emulationstation (the ES C++ binary; also needed because it
#                                      depends on batocera-es-system and, under
#                                      BR2_PER_PACKAGE_DIRECTORIES, snapshots
#                                      its own now-stale copy of es_systems.cfg
#                                      otherwise — see AGENTS.md's "per-package
#                                      snapshot staleness cascades through
#                                      dependent packages" note)
#        - batocera-es-web-ui        (depends on batocera-emulationstation,
#                                      same stale-snapshot risk one level
#                                      further down the chain)
#        - batocera-system           (writes /usr/share/batocera/batocera.version
#                                      by shelling out to `git rev-parse --short
#                                      HEAD` in its INSTALL_TARGET_CMDS recipe.
#                                      Buildroot has no file-level dependency to
#                                      notice "the git HEAD moved" — once this
#                                      package's install stamp is satisfied it
#                                      never re-runs, so batocera.version silently
#                                      goes stale (confirmed: a build done here
#                                      days after the commit it actually reflects
#                                      still reported the old commit/date) unless
#                                      explicitly dircleaned. Included here so
#                                      every refresh keeps the shipped version
#                                      string honest, not just the ES pipeline.
#
# This script only cleans — it deliberately does NOT build these packages
# itself. Building is left to whatever full build you run afterwards, which
# already walks Buildroot's real DEPENDENCIES graph (with proper parallelism)
# to rebuild anything a dirclean here made stale. Building all 5 here too
# would just be redundant work re-done by that later full build.
#
# All 5 dircleans are batched into a single `make ... CMD="pkg1-dirclean
# pkg2-dirclean ..."` invocation — verified safe (2026-07-27) since dirclean
# targets are independent `rm -Rf`s with no ordering dependency on each
# other. This is a narrower case than two related bugs hit earlier the same
# day while this script still built packages itself:
#   - Combining multiple packages' dirclean+build PAIRS into one CMD= string
#     was unreliable: even with a real Buildroot DEPENDENCIES edge between
#     the two packages, the second package's build silently no-op'd ("make:
#     Nothing to be done for '<pkg>'") despite its dirclean sibling having
#     just run in the same invocation, and the final image kept shipping
#     stale output despite `make` reporting exit 0 the whole way through.
#     See USER-INSTRUCTIONS.md's "configgen-defaults case study".
#   - Even a SINGLE package's own `CMD="<pkg>-dirclean <pkg>"` broke:
#     dirclean's `rm -Rf` of that package's per-package snapshot happens
#     mid-invocation, but Buildroot's per-package-directory preparation
#     (which hardlinks each dependency's host/target output, e.g.
#     host-python3, into that snapshot) is only evaluated once per `make`
#     process and doesn't re-run afterwards within the same invocation.
#     Concretely this broke batocera-configgen's install step with
#     ".../per-package/batocera-configgen/host/bin/python3: No such file or
#     directory".
# Both were specifically about mixing dirclean and build in the same
# invocation. Since this script no longer builds at all, that whole class of
# bug doesn't apply here — only the (verified-safe) dirclean batching does.
#
# None of these package targets depend on genimage/target-finalize, so this
# never triggers a full image build — dirclean only removes prior output
# under output/<TARGET>/{staging,target,per-package}/. Run your own full
# image build separately when ready.
#
# Usage: ./refresh-board-es.sh [--quick]
#   TARGET=<buildroot target>   (env var, default: zen3-focused)
#   --quick, -q  (or QUICK=1)   skip the two "full clean" extras, saving ~3-5 min:
#                                 - the sweep of ~50 in-repo data packages, and
#                                 - wiping output/<target>/target.
#                               Still dircleans the ES/configgen/python-common/
#                               batocera-launch* packages (stale stamps there
#                               broke launching entirely — see below), so it is
#                               safe for iteration builds. Use the FULL refresh
#                               (no flag) for any image you will test or ship: only
#                               that guarantees no leftover files from earlier
#                               builds end up in the rootfs.

set -euo pipefail

TARGET="${TARGET:-zen3-focused}"
QUICK="${QUICK:-}"
for arg in "$@"; do
	case "$arg" in
		--quick|-q) QUICK=1 ;;
		*) echo "error: unrecognized argument: $arg (usage: $0 [--quick])" >&2; exit 1 ;;
	esac
done
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Local-source (OVERRIDE_SRCDIR / python-src) packages have NO stamp dependency
# on their own source changing, so a stale one silently ships old code. Found
# the hard way 2026-09-19: python-batocera-common's stamp predated an upstream
# merge, so the image shipped a batocera_common missing 8 modules that
# batocera-launch imports (ImportError on every game launch) and the zen3
# build died in batocera-labwc on the same cause. Everything that consumes
# python-batocera-common must be refreshed with it, because under
# BR2_PER_PACKAGE_DIRECTORIES each dependent holds its own snapshot copy.
# dirclean of a package that isn't enabled on this board is a harmless no-op.
PACKAGES=(
	python-batocera-common
	host-python-batocera-common
	batocera-bezel-overlay
	batocera-launch
	host-batocera-es-system
	batocera-es-system
	batocera-emulationstation
	batocera-es-web-ui
	batocera-system
	hotkeygen
	batocera-led-handheld
	batocera-labwc
	host-batocera-labwc
	# every batocera-launch-<emu> sub-package (all depend on python-batocera-common)
	batocera-launch-cdogs batocera-launch-cgenius batocera-launch-dolphin
	batocera-launch-drastic batocera-launch-fallout batocera-launch-flycast
	batocera-launch-kodi batocera-launch-linuxloader batocera-launch-mupen64plus
	batocera-launch-openjazz batocera-launch-openjk batocera-launch-openjkdf2
	batocera-launch-openmohaa batocera-launch-pcsx2 batocera-launch-rpcs3
	batocera-launch-libretro batocera-launch-libretro-mame batocera-launch-mame
	batocera-launch-mame-common batocera-launch-xemu-chihiro
	# fork-only: ares' launcher (configgen was removed upstream 2026-10-04)
	batocera-launch-ares
)

# Plus any other local-source (*-custom) package already in this board's build
# dir, so a newly added python-src package can't be missed. libretro-mame is
# excluded: it's OVERRIDE_SRCDIR too but a multi-GB, multi-hour rebuild that
# has its own refresh path (`make libretro-mame-rebuild all`).
# A build dir can outlive its package (batocera-configgen-custom after upstream
# deleted configgen, 2026-10-04): dirclean of a package with no .mk is a make
# error ("No rule to make target"), which would abort this script, so only
# add names that still have a <name>.mk.
if [ -d "${REPO_ROOT}/output/${TARGET}/build" ]; then
	KNOWN_MKS=" $(find "${REPO_ROOT}/package" "${REPO_ROOT}/python-src" -name '*.mk' -printf '%f ' | sed 's/\.mk / /g')"
	for d in "${REPO_ROOT}/output/${TARGET}/build"/*-custom; do
		[ -d "$d" ] || continue
		name="$(basename "$d" -custom)"
		[ "$name" = "libretro-mame" ] && continue
		case "${KNOWN_MKS}" in *" ${name#host-} "*) ;; *) echo "==> skipping ${name}: build dir left over, package no longer exists"; continue ;; esac
		case " ${PACKAGES[*]} " in *" ${name} "*) ;; *) PACKAGES+=("$name") ;; esac
	done
fi

cd "${REPO_ROOT}"

echo "==> Regenerating defconfig/config for target: ${TARGET}"
make "${TARGET}-defconfig"
make "${TARGET}-config" BATCH_MODE=1

# In-repo "data" packages (empty <PKG>_SOURCE =, install straight from their own
# package dir: desktopapps, scripts, udev rules, gun configs, ...). Their
# per-package tree and .files-list.txt persist across builds, so a file the
# package stopped installing (e.g. batocera-desktopapps' model2emu-config.desktop
# after upstream dropped model2emu) keeps shipping forever unless the package is
# dircleaned. All are tiny, so refresh them every time.
if [ -z "${QUICK}" ]; then
DATA_PKGS="$(python3 - "${REPO_ROOT}" "${TARGET}" <<'PYEOF'
import glob, os, re, sys
root, target = sys.argv[1], sys.argv[2]
built = set(os.listdir(f"{root}/output/{target}/per-package")) if os.path.isdir(f"{root}/output/{target}/per-package") else set()
names = set()
for mk in glob.glob(f"{root}/package/**/*.mk", recursive=True) + glob.glob(f"{root}/python-src/**/*.mk", recursive=True):
    for m in re.finditer(r"^([A-Z0-9_]+)_SOURCE\s*[:?]?=\s*$", open(mk, errors="ignore").read(), re.M):
        n = m.group(1).lower().replace("_", "-")
        if n in built:
            names.add(n)
print(" ".join(sorted(names)))
PYEOF
)"
for n in ${DATA_PKGS}; do
	case " ${PACKAGES[*]} " in *" ${n} "*) ;; *) PACKAGES+=("$n") ;; esac
done
else
	echo "==> --quick: skipping in-repo data-package sweep (run without --quick before building an image to test or ship)"
fi

DIRCLEAN_CMD=""
for pkg in "${PACKAGES[@]}"; do
	DIRCLEAN_CMD="${DIRCLEAN_CMD} ${pkg}-dirclean"
done

echo "==> Dircleaning EmulationStation/configgen pipeline for target: ${TARGET}"
echo "    Packages: ${PACKAGES[*]}"
echo "    (dirclean only, no build — that happens on your next full build)"
make "${TARGET}-build" BATCH_MODE=1 CMD="${DIRCLEAN_CMD}"

# Buildroot's target-finalize only COPIES per-package trees into target/ and
# never deletes, so files from earlier builds (deleted generators, old defaults
# yml, retired .desktop entries) ship forever. Discovered 2026-09-19: ~60 stale
# legacy generator dirs + model2emu leftovers in an image after the launcher
# migration. Removing target/ makes the next build regenerate it purely from the
# per-package trees (safe in per-package mode; target-finalize repopulates it).
if [ -z "${QUICK}" ]; then
	echo "==> Removing output/${TARGET}/target so it is regenerated cleanly"
	rm -rf "${REPO_ROOT}/output/${TARGET}/target"
else
	echo "==> --quick: keeping output/${TARGET}/target (stale leftovers from earlier builds may remain)"
fi

echo "==> Done. Cleaned output under output/${TARGET}/{staging,target,per-package}/."
echo "    Build the full image yourself when ready, e.g.: make ${TARGET}-build"
