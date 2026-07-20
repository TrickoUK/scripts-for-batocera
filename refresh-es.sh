#!/bin/bash
#
# build-es.sh — rebuild the EmulationStation / configgen option pipeline
# after changing or adding an option somewhere in that stack (e.g. a
# libretro core's *.core.yml, configgen's libretroOptions.py, es_systems.yml,
# es_features.yml, the batocera-es-system codegen tool, or the
# EmulationStation fork's C++ itself), WITHOUT rebuilding individual
# emulator/core packages and WITHOUT building the full image.
#
# Rebuilds, redundantly rather than minimally (each package's build/install
# stamps are removed with -dirclean first, since several of these packages
# have no OVERRIDE_SRCDIR for Buildroot to watch for staleness):
#   - batocera-configgen        (runtime option-generation code, read by
#                                 configgen at game-launch time)
#   - host-batocera-es-system   (host codegen tool that builds es_systems.cfg
#                                 / es_features.cfg from the yml sources)
#   - batocera-es-system        (runs the host tool, installs the generated
#                                 cfg files to the target)
#   - batocera-emulationstation (the ES C++ binary itself, in case the
#                                 change was on the frontend side, e.g. the
#                                 GuiMenu.cpp option-rendering code)
#
# None of these package targets depend on genimage/target-finalize, so this
# never triggers a full image build — output lands under
# output/<TARGET>/{staging,target}/ only. Run your own full image build
# separately when ready.
#
# Usage: ./build-es.sh
#   TARGET=<buildroot target>   (env var, default: x86_64-arcade)

set -euo pipefail

TARGET="${TARGET:-x86_64-arcade}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PACKAGES=(
	batocera-configgen
	host-batocera-es-system
	batocera-es-system
	batocera-emulationstation
)

CMD=""
for pkg in "${PACKAGES[@]}"; do
	CMD="${CMD} ${pkg}-dirclean ${pkg}"
done

echo "==> Rebuilding EmulationStation/configgen pipeline for target: ${TARGET}"
echo "    Packages: ${PACKAGES[*]}"
echo "    (no individual emulator/core packages, no full image build)"

cd "${REPO_ROOT}"
make "${TARGET}-build" BATCH_MODE=1 CMD="${CMD}"

echo "==> Done. Updated output under output/${TARGET}/{staging,target}/."
echo "    Build the full image yourself when ready, e.g.: make ${TARGET}-build"
