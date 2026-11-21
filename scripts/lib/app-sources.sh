# Copyright (C) 2026 Ardhitama
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms for the FanMac name and icon: see NOTICE.
#
# Sourced by scripts/test.sh and scripts/capture-ui.sh. They build FanMac's
# sources into their own program, where nothing may drive the fans.
#
# The compiler flags follow the app target's settings in fan.xcodeproj:
# SWIFT_VERSION, SWIFT_DEFAULT_ACTOR_ISOLATION, SWIFT_APPROACHABLE_CONCURRENCY,
# the upcoming features and MACOSX_DEPLOYMENT_TARGET. Change them together.

deployment_target=26.1

# prepare_app_sources <repo> <dest>
# Copies the app's Swift sources into <dest> in one folder, as the app target
# compiles them; drops the app's entry point; points the helper path at a file
# that doesn't exist, so no fan write can run; and compiles the asset catalog
# to <dest>/Assets.car with its symbols (.menuBarIcon, .accent), as an Xcode
# build does. The symbols look for Assets.car in the bundle that holds the code.
prepare_app_sources() {
  local repo=$1 dest=$2 file name
  mkdir -p "$dest"
  while IFS= read -r file; do
    name=$(basename "$file")
    if [[ -e $dest/$name ]]; then
      echo "${0##*/}: two sources are named $name; rename one" >&2
      return 1
    fi
    cp "$file" "$dest/"
  done < <(find "$repo/Shared" "$repo/fan" -name '*.swift')

  python3 - "$dest" <<'PY' || return 1
import pathlib, sys

src = pathlib.Path(sys.argv[1])

def replace_once(name, old, new):
    path = src / name
    text = path.read_text(encoding="utf-8")
    if old not in text:
        sys.exit(f"{name} no longer contains {old!r}; update scripts/lib/app-sources.sh")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")

replace_once("FanMacApp.swift", "@main\n", "")
replace_once("FanController.swift", "        PermissionsManager.helperPath\n",
             '        "/nonexistent/fanmac-smc-helper"\n')
PY

  # Two passes, as Xcode runs them: asking for symbols writes only the symbols.
  # actool writes no symbols without a bundle identifier.
  local actool=(xcrun actool "$repo/fan/Assets.xcassets" --compile "$dest" --output-format human-readable-text
                --platform macosx --target-device mac --minimum-deployment-target "$deployment_target"
                --bundle-identifier com.ardhitama.fanmac.app)
  "${actool[@]}" --generate-swift-asset-symbols "$dest/GeneratedAssetSymbols.swift" >/dev/null || return 1
  "${actool[@]}" >/dev/null || return 1
  if [[ ! -f $dest/GeneratedAssetSymbols.swift || ! -f $dest/Assets.car ]]; then
    echo "${0##*/}: actool wrote no asset catalog or symbols" >&2
    return 1
  fi
}

# compile_app_module <swiftc arguments…>
# Runs swiftc with the app target's language settings, for this Mac.
compile_app_module() {
  local features=(MemberImportVisibility NonisolatedNonsendingByDefault InferIsolatedConformances
                  InferSendableFromCaptures DisableOutwardActorInference GlobalActorIsolatedTypesUsability)
  local flags=() feature
  for feature in "${features[@]}"; do flags+=(-enable-upcoming-feature "$feature"); done
  xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor -module-name FanMac \
    "${flags[@]}" -target "$(uname -m)-apple-macos$deployment_target" -Onone -suppress-warnings "$@"
}
