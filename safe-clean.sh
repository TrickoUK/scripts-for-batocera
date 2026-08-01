#!/bin/bash
# Targeted cleanup of orphaned build artifacts (dl/, output/<target>/build/,
# output/<target>/per-package/, and the nested per-package staleness case)
# via scripts/linux/cleanup_build_artifacts.py. See
# my-docs/guides/build-artifact-cleanup.md for what each category means.
#
# Runs against the current-version info from `show-info`, not a blind
# wipe - "safe" here means targeted and current-version-aware, not
# unattended: it still prints the full candidate list and asks for a typed
# "yes" before deleting anything. Pass --yes to skip that prompt, or any
# other cleanup_build_artifacts.py flag straight through (e.g. --boards,
# --only, --json).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "$SCRIPT_DIR/scripts/linux/cleanup_build_artifacts.py" \
    --apply dl,build,per-package,nested \
    "$@"
