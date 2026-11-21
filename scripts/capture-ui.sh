#!/usr/bin/env bash
# Copyright (C) 2026 Ardhitama
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms for the FanMac name and icon: see NOTICE.
#
# Captures FanMac's popover, Settings and widget gallery in each state that
# tools/ui-capture/Capture.swift knows, one PNG per state, to look over
# together after a UI change.
#
# Usage: scripts/capture-ui.sh [state ...]   (default: every state)
#
# The PNGs go to build/ui-captures/. Each state opens its window on screen
# for about three seconds. Terminal needs Screen Recording access (System
# Settings → Privacy & Security) for the screenshots. Nothing here drives the
# fans: the helper path points at a file that doesn't exist, as in
# scripts/test.sh, and the running FanMac is left alone.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/scripts/lib/app-sources.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/fanmac-ui-capture.XXXXXX")
# The program's defaults domain is its name and holds only fixture values.
# cfprefsd leaves an empty plist after the delete, so that goes too.
cleanup() {
  rm -rf "$work"
  defaults delete fanmac-ui-capture >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/fanmac-ui-capture.plist"
}
trap cleanup EXIT
out=$repo/build/ui-captures
mkdir -p "$out"

prepare_app_sources "$repo" "$work/src"
cp "$repo/tools/ui-capture/Capture.swift" "$work/src/"
echo "Building the capture program…"
compile_app_module "$work/src"/*.swift -o "$work/fanmac-ui-capture"
# The About section's documents, where the program's Bundle.main looks.
cp "$repo/LICENSE" "$repo/NOTICE" "$work/"

if [[ $# -gt 0 ]]; then
  states=("$@")
else
  states=()
  while IFS= read -r state; do states+=("$state"); done < <("$work/fanmac-ui-capture" --list)
fi

failed=0
for state in "${states[@]}"; do
  # A failed state must not leave an earlier run's picture behind.
  rm -f "$out/$state.png"
  if "$work/fanmac-ui-capture" "$state" "$out/$state.png" >/dev/null; then
    echo "  $state"
  else
    echo "  $state: failed" >&2
    failed=1
  fi
done
echo "Captures are in $out"
exit $failed
