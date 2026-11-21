#!/usr/bin/env bash
# Copyright (C) 2026 Ardhitama
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms for the FanMac name and icon: see NOTICE.
#
# Builds FanMac's sources and the tests in fanTests/ into one XCTest bundle
# and runs it.
#
# Usage: scripts/test.sh [TestClass ...]   (default: every file in fanTests/)
#
# The Xcode project has no test target on purpose. A hosted test would start
# a second FanMac beside the one in use, and the two would share the control
# socket and the fans. Here nothing launches the app, and the helper path
# points at a file that doesn't exist, so no test can write the fans.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/scripts/lib/app-sources.sh"

if [[ $# -gt 0 ]]; then
  tests=("$@")
else
  tests=()
  for file in "$repo"/fanTests/*.swift; do tests+=("$(basename "$file" .swift)"); done
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/fanmac-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
src=$work/src
bundle=$work/FanMacTests.xctest
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

prepare_app_sources "$repo" "$src"
mv "$src/Assets.car" "$bundle/Contents/Resources/"
for test in "${tests[@]}"; do
  if [[ ! -f $repo/fanTests/$test.swift ]]; then
    echo "scripts/test.sh: no fanTests/$test.swift" >&2
    exit 2
  fi
  cp "$repo/fanTests/$test.swift" "$src/"
done

# The tests and the app share one module, so they don't import it.
python3 - "$src" "${tests[@]}" <<'PY'
import pathlib, sys

src = pathlib.Path(sys.argv[1])
for test in sys.argv[2:]:
    path = src / f"{test}.swift"
    text = path.read_text(encoding="utf-8")
    if "@testable import FanMac\n" not in text:
        sys.exit(f"scripts/test.sh: fanTests/{test}.swift doesn't import FanMac")
    path.write_text(text.replace("@testable import FanMac\n", "", 1), encoding="utf-8")
PY

cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FanMacTests</string>
<key>CFBundleIdentifier</key><string>com.ardhitama.fanmac.tests</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST

platform=$(xcrun --show-sdk-platform-path)/Developer
echo "Building ${#tests[@]} test files…"
compile_app_module \
  -F "$platform/Library/Frameworks" -I "$platform/usr/lib" -L "$platform/usr/lib" -framework XCTest \
  -Xlinker -bundle -Xlinker -rpath -Xlinker "$platform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$platform/usr/lib" \
  "$src"/*.swift -o "$bundle/Contents/MacOS/FanMacTests"

xcrun xctest "$bundle"
