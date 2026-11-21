#!/usr/bin/env bash
# Copyright (C) 2026 Ardhitama
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional terms for the FanMac name and icon: see NOTICE.
#
# Builds, signs, notarizes and publishes a FanMac release and its Homebrew cask.
#
# Usage: NOTARY_PROFILE=<profile> scripts/release.sh
#
# The version is MARKETING_VERSION in fan.xcodeproj. Commit it and its
# CHANGELOG section on main first: the release adds no commits. It:
#   1. builds a universal Release from the clean main checkout, signs it
#      inside-out with Developer ID, notarizes and staples it, and checks the
#      archive it will upload;
#   2. writes and audits the cask, uploads fanmac-macos.tar.gz and its
#      checksum to a draft release, fanmac-v<version>, in the tap repository,
#      and checks the uploaded copy;
#   3. pushes main and the tag v<version> to the source repository;
#   4. publishes the release, waits for the tap's attestation workflow, and
#      verifies the archive's attestation;
#   5. pushes the cask to the tap.
# Running it again after a failure is safe. A draft release from a run that
# stopped is deleted and built again. Once the release is published, a rerun
# builds nothing: it checks the published archive and its attestation, then
# pushes the cask if the tap doesn't have it yet.
#
# Needs Xcode, gh signed in with the repo and workflow scopes, a Developer ID
# Application identity in the keychain (CODESIGN_IDENTITY names another), a
# notarytool keychain profile (xcrun notarytool store-credentials), and the tap:
#   brew trust --tap ardhitama/tap && brew tap ardhitama/tap
set -euo pipefail

SOURCE_REPO=ardhitama/fanmac
TAP_REPO=ardhitama/homebrew-tap
TAP_NAME=ardhitama/tap
ARCHIVE_NAME=fanmac-macos.tar.gz
CHECKSUM_NAME=fanmac-macos.sha256
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application}"
# Signed inside-out: these first, then the app.
NESTED_CODE=(Contents/Resources/smc-helper Contents/Helpers/fanmac)
EXECUTABLES=(Contents/MacOS/FanMac "${NESTED_CODE[@]}")
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

die() {
    printf 'release: %s\n' "$*" >&2
    exit 1
}

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[[ -n "${NOTARY_PROFILE:-}" ]] || \
    die "set NOTARY_PROFILE to a notarytool keychain profile (see xcrun notarytool store-credentials)"
for command_name in brew codesign ditto gh git lipo plutil shasum spctl tar xcodebuild xcrun; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

# --- Preflight: nothing public changes before the draft release.

[[ "$(git branch --show-current)" == main ]] || die "check out main first"
[[ -z "$(git status --porcelain)" ]] || die "commit or stash the working tree's changes first"
VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);$/\1/p' fan.xcodeproj/project.pbxproj | sort -u)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "every MARKETING_VERSION in fan.xcodeproj must be the same major.minor.patch, found: ${VERSION:-none}"
grep -q "^## \[$VERSION\]" CHANGELOG.md || die "CHANGELOG.md has no section for $VERSION"
SOURCE_TAG="v$VERSION"
RELEASE_TAG="fanmac-v$VERSION"

[[ "$(git remote get-url origin)" == "https://github.com/$SOURCE_REPO.git" ]] || \
    die "origin must be https://github.com/$SOURCE_REPO.git"
git fetch --quiet origin
if git rev-parse --verify --quiet refs/remotes/origin/main >/dev/null; then
    git merge-base --is-ancestor origin/main HEAD || die "main has diverged from origin/main; reconcile it first"
fi

# The commit each copy of the source tag names, or nothing; an annotated tag's
# peeled (^{}) line names its commit.
LOCAL_TAG_COMMIT="$(git rev-parse --verify --quiet "refs/tags/$SOURCE_TAG^{commit}" || true)"
REMOTE_TAG_COMMIT="$(git ls-remote --tags origin | awk -v tag="refs/tags/$SOURCE_TAG" '
    $2 == tag "^{}" { peeled = $1 } $2 == tag { named = $1 }
    END { print (peeled != "" ? peeled : named) }')"

# none, draft or published. Listing includes drafts, which `gh release view`
# by tag can miss.
RELEASE_STATE="$(gh release list --repo "$TAP_REPO" --limit 200 --json tagName,isDraft --jq "
    map(select(.tagName == \"$RELEASE_TAG\"))
    | if length == 0 then \"none\" elif .[0].isDraft then \"draft\" else \"published\" end")"

if [[ "$RELEASE_STATE" == published ]]; then
    [[ -n "$REMOTE_TAG_COMMIT" ]] || \
        die "$RELEASE_TAG is published, but $SOURCE_REPO has no tag $SOURCE_TAG; push it, then run this again"
else
    # A tag left by a run that stopped before publishing may name this commit.
    HEAD_COMMIT="$(git rev-parse HEAD)"
    for tag_commit in "$LOCAL_TAG_COMMIT" "$REMOTE_TAG_COMMIT"; do
        [[ -z "$tag_commit" || "$tag_commit" == "$HEAD_COMMIT" ]] || \
            die "tag $SOURCE_TAG names ${tag_commit:0:7}, not HEAD; bump MARKETING_VERSION, or delete the tag if $VERSION never shipped"
    done
fi

TAP_DIR="$(brew --repository)/Library/Taps/ardhitama/homebrew-tap"
[[ -d "$TAP_DIR/.git" ]] || die "the tap is not installed; run: brew trust --tap $TAP_NAME && brew tap $TAP_NAME"
[[ "$(git -C "$TAP_DIR" branch --show-current)" == main ]] || die "the tap checkout must be on main: $TAP_DIR"
[[ -z "$(git -C "$TAP_DIR" status --porcelain)" ]] || die "the tap checkout has uncommitted changes: $TAP_DIR"
git -C "$TAP_DIR" pull --quiet --ff-only origin main || die "could not bring the tap checkout up to date: $TAP_DIR"
[[ "$(gh api "repos/$TAP_REPO/actions/workflows/release-attestation.yml" --jq .state)" == active ]] || \
    die "the release attestation workflow in $TAP_REPO is not active"

if [[ "$RELEASE_STATE" == draft ]]; then
    printf '==> Deleting the draft release %s left by an earlier run\n' "$RELEASE_TAG"
    # Not --cleanup-tag: it fails after deleting the draft when the tag is
    # already gone. The step below deletes the tag if it is still there.
    gh release delete "$RELEASE_TAG" --repo "$TAP_REPO" --yes
    RELEASE_STATE=none
fi
if [[ "$RELEASE_STATE" == none ]] && \
    git ls-remote --exit-code --tags "https://github.com/$TAP_REPO.git" "refs/tags/$RELEASE_TAG" >/dev/null 2>&1; then
    # Only this script makes fanmac-v tags, and a tag without a release is
    # left by a run that stopped before creating its draft.
    printf '==> Deleting the tag %s left by an earlier run\n' "$RELEASE_TAG"
    git -C "$TAP_DIR" push --quiet origin ":refs/tags/$RELEASE_TAG"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fanmac-release.XXXXXX")"
CASK="$TAP_DIR/Casks/fanmac.rb"
CASK_PUBLISHED=0
cleanup() {
    # Each copy of the app built or unpacked here registered itself with
    # LaunchServices; unregister them so Open With and Spotlight don't offer
    # deleted copies.
    if [[ -d "$WORK" ]]; then
        find "$WORK" -type d -name FanMac.app -prune -exec "$LSREGISTER" -u {} \; 2>/dev/null || true
    fi
    rm -rf "$WORK"
    # A cask written for a release that did not finish must not stay in the tap.
    if [[ "$CASK_PUBLISHED" == 0 && -n "$(git -C "$TAP_DIR" status --porcelain -- Casks/fanmac.rb)" ]]; then
        if git -C "$TAP_DIR" ls-files --error-unmatch Casks/fanmac.rb >/dev/null 2>&1; then
            git -C "$TAP_DIR" checkout -- Casks/fanmac.rb
        else
            rm -f "$CASK"
        fi
    fi
}
trap cleanup EXIT

# Checks an archive as a user receives it: one app, signed with Developer ID
# and the hardened runtime, notarized, universal, and at this version.
verify_archive() {
    local archive="$1"
    local directory="$2"
    local app="$directory/FanMac.app"
    local path arch details
    mkdir -p "$directory"
    tar -xzf "$archive" -C "$directory"
    [[ "$(ls -A "$directory")" == FanMac.app ]] || die "$archive must hold only FanMac.app"
    codesign --verify --deep --strict "$app" || die "$archive: the app's signature is invalid"
    xcrun stapler validate -q "$app" || die "$archive: the app has no stapled notarization ticket"
    spctl --assess --type execute "$app" || die "$archive: Gatekeeper rejects the app"
    for path in "${EXECUTABLES[@]}"; do
        for arch in arm64 x86_64; do
            lipo "$app/$path" -verify_arch "$arch" || die "$archive: $path has no $arch slice"
        done
        details="$(codesign --display --verbose=2 "$app/$path" 2>&1)"
        grep -q '^Authority=Developer ID Application:' <<<"$details" || \
            die "$archive: $path is not signed with Developer ID"
        grep -q '^CodeDirectory .*flags=.*runtime' <<<"$details" || \
            die "$archive: $path lacks the hardened runtime"
    done
    [[ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" == "$VERSION" ]] || \
        die "$archive: the app's version is not $VERSION"
}

# Writes the cask for $SHA256 into the tap checkout and audits it.
# The cask installs the command with `binary` and leaves the root-owned helper,
# its sudoers rule and the app's own /usr/local/bin link to `zap`: an upgrade
# runs `uninstall`, and removing the helper there would make every upgrade ask
# for an administrator password to put it back.
write_cask() {
    mkdir -p "$TAP_DIR/Casks"
    cat > "$CASK" <<CASK
cask "fanmac" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/$TAP_REPO/releases/download/fanmac-v#{version}/$ARCHIVE_NAME"
  name "FanMac"
  desc "Monitor temperatures and control fan speeds from the menu bar"
  homepage "https://github.com/$SOURCE_REPO"

  depends_on macos: :tahoe

  app "FanMac.app"
  binary "FanMac.app/Contents/Helpers/fanmac"

  uninstall quit: "com.ardhitama.fanmac.app"

  zap delete: [
        "/etc/sudoers.d/smc-fan-helper",
        "/Library/PrivilegedHelperTools/fanmac-smc-helper",
        "/usr/local/bin/fanmac",
      ],
      trash:  [
        "~/Library/Application Support/FanMac",
        "~/Library/Preferences/com.ardhitama.fanmac.app.plist",
        "~/Library/Preferences/tests.fan.plist",
      ]

  caveats <<~EOS
    FanMac changes fan speeds through a helper that runs as root. Open FanMac
    and click Install Helper once; it asks for an administrator password.
    To remove the helper and its sudoers rule with the app, run:
      brew uninstall --zap --cask fanmac
  EOS
end
CASK
    brew style "$CASK" || die "the cask fails brew style: $CASK"
    brew audit --cask --strict "$TAP_NAME/fanmac" || die "the cask fails brew audit: $CASK"
}

# Downloads the release's archive and checksum into $WORK/public by asset ID,
# then checks them. GitHub's list view of a draft can omit assets just
# uploaded, and its tag view of a release just published can too; the
# release's own asset list is current.
download_release() {
    local release_id asset_ids asset_name asset_id
    release_id="$(gh release view "$RELEASE_TAG" --repo "$TAP_REPO" --json databaseId --jq .databaseId)"
    asset_ids="$(gh api "repos/$TAP_REPO/releases/$release_id/assets" --paginate --jq '.[] | [.name, .id] | @tsv')"
    mkdir -p "$WORK/public"
    for asset_name in "$ARCHIVE_NAME" "$CHECKSUM_NAME"; do
        asset_id="$(awk -F '\t' -v name="$asset_name" '$1 == name { print $2; exit }' <<<"$asset_ids")"
        [[ -n "$asset_id" ]] || die "the release $RELEASE_TAG is missing $asset_name"
        gh api -H 'Accept: application/octet-stream' "repos/$TAP_REPO/releases/assets/$asset_id" \
            > "$WORK/public/$asset_name"
    done
    (cd "$WORK/public" && shasum -a 256 -c "$CHECKSUM_NAME") || die "the released archive does not match its checksum"
    verify_archive "$WORK/public/$ARCHIVE_NAME" "$WORK/verify-public"
}

# Waits for the attestation run of this release created at or after $1 (any
# run when $1 is empty). A release event's run has the tag as its branch.
wait_for_attestation() {
    local since="$1" run_id="" run_state deadline=$((SECONDS + 600))
    while (( SECONDS < deadline )); do
        run_id="$(gh run list --repo "$TAP_REPO" --workflow release-attestation.yml --event release \
            --limit 50 --json databaseId,headBranch,createdAt \
            --jq "map(select(.headBranch == \"$RELEASE_TAG\" and .createdAt >= \"$since\")) | first | .databaseId // empty" \
            2>/dev/null || true)"
        if [[ -n "$run_id" ]]; then
            run_state="$(gh run view "$run_id" --repo "$TAP_REPO" --json status,conclusion \
                --jq '.status + " " + .conclusion' 2>/dev/null || true)"
            case "$run_state" in
                "completed success") return 0 ;;
                completed*) die "the attestation workflow failed: https://github.com/$TAP_REPO/actions/runs/$run_id; rerun it with gh run rerun $run_id --repo $TAP_REPO, then run this again" ;;
            esac
        fi
        sleep 5
    done
    die "the attestation workflow did not finish within ten minutes (run: ${run_id:-none})"
}

PUBLISHED_AFTER=""
if [[ "$RELEASE_STATE" == published ]]; then
    printf '==> %s is already published; checking it and its cask\n' "$RELEASE_TAG"
    download_release
    SHA256="$(shasum -a 256 "$WORK/public/$ARCHIVE_NAME" | awk '{ print $1 }')"
    write_cask
else
    # --- 1. Build, sign, notarize, package

    printf '==> Building FanMac %s\n' "$VERSION"
    # A generic destination builds every architecture in ARCHS; without one,
    # xcodebuild builds only this Mac's. Signing is off so the steps below sign
    # the bundle once, with Developer ID.
    xcodebuild -quiet \
        -project fan.xcodeproj \
        -scheme fan \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$WORK/build" \
        clean build \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        DEVELOPMENT_TEAM=""
    APP="$WORK/FanMac.app"
    ditto "$WORK/build/Build/Products/Release/FanMac.app" "$APP"

    printf '==> Signing with %s\n' "$SIGNING_IDENTITY"
    for path in "${NESTED_CODE[@]}"; do
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/$path"
    done
    codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"

    printf '==> Notarizing\n'
    ditto -c -k --keepParent "$APP" "$WORK/notary.zip"
    # notarytool's exit status does not say whether Apple accepted the app; the
    # status in its result does, so read that.
    xcrun notarytool submit "$WORK/notary.zip" --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format json > "$WORK/notary.json" || true
    NOTARY_STATUS="$(plutil -extract status raw "$WORK/notary.json" 2>/dev/null || true)"
    NOTARY_ID="$(plutil -extract id raw "$WORK/notary.json" 2>/dev/null || true)"
    if [[ "$NOTARY_STATUS" != Accepted ]]; then
        cat "$WORK/notary.json" >&2 || true
        [[ -z "$NOTARY_ID" ]] || xcrun notarytool log "$NOTARY_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        die "Apple did not accept the notarization (status: ${NOTARY_STATUS:-none})"
    fi
    xcrun stapler staple "$APP"

    mkdir "$WORK/package"
    ditto "$APP" "$WORK/package/FanMac.app"
    # COPYFILE_DISABLE keeps macOS tar from adding AppleDouble (._) files.
    COPYFILE_DISABLE=1 tar -czf "$WORK/$ARCHIVE_NAME" -C "$WORK/package" FanMac.app
    SHA256="$(shasum -a 256 "$WORK/$ARCHIVE_NAME" | awk '{ print $1 }')"
    printf '%s  %s\n' "$SHA256" "$ARCHIVE_NAME" > "$WORK/$CHECKSUM_NAME"

    verify_archive "$WORK/$ARCHIVE_NAME" "$WORK/verify-local"

    # --- 2. Cask, then the draft release

    write_cask
    printf '==> Uploading a draft release %s to %s\n' "$RELEASE_TAG" "$TAP_REPO"
    # A draft release does not reliably create its tag, and publishing a draft
    # whose tag is missing fails, so create the tag first.
    git -C "$TAP_DIR" push --quiet origin "HEAD:refs/tags/$RELEASE_TAG"
    RELEASE_NOTES="FanMac $VERSION for macOS 26.1 or later, on Apple silicon or Intel. Signed with Developer ID and notarized by Apple.

\`\`\`sh
brew trust --tap $TAP_NAME
brew tap $TAP_NAME
brew install --cask fanmac
\`\`\`

Or download \`$ARCHIVE_NAME\` and move FanMac.app to Applications.

Changes: https://github.com/$SOURCE_REPO/blob/$SOURCE_TAG/CHANGELOG.md
Source code: https://github.com/$SOURCE_REPO/tree/$SOURCE_TAG
License: GPL-3.0-or-later, with additional terms for the FanMac name and icon (NOTICE). No warranty."
    gh release create "$RELEASE_TAG" \
        --repo "$TAP_REPO" \
        --draft \
        --verify-tag \
        --title "FanMac $VERSION" \
        --notes "$RELEASE_NOTES"
    gh release upload "$RELEASE_TAG" "$WORK/$ARCHIVE_NAME" "$WORK/$CHECKSUM_NAME" --repo "$TAP_REPO"

    download_release
    cmp -s "$WORK/$ARCHIVE_NAME" "$WORK/public/$ARCHIVE_NAME" || die "the uploaded archive differs from the built one"

    # --- 3. Source

    printf '==> Pushing main and %s to %s\n' "$SOURCE_TAG" "$SOURCE_REPO"
    git push --quiet origin main
    # An earlier run may have made the tag; preflight checked it names HEAD.
    [[ -n "$LOCAL_TAG_COMMIT" ]] || git tag -a "$SOURCE_TAG" -m "FanMac $VERSION"
    [[ -n "$REMOTE_TAG_COMMIT" ]] || git push --quiet origin "refs/tags/$SOURCE_TAG"

    # --- 4. Publish

    # Taken before publishing: the run the release event starts can be created
    # within the same second.
    PUBLISHED_AFTER="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    gh release edit "$RELEASE_TAG" --repo "$TAP_REPO" --draft=false >/dev/null
    [[ "$(gh release view "$RELEASE_TAG" --repo "$TAP_REPO" --json isDraft --jq .isDraft)" == false ]] || \
        die "GitHub did not publish $RELEASE_TAG"
fi

# --- 4, continued: attest. A rerun after publishing resumes here.

printf '==> Waiting for the release attestation\n'
wait_for_attestation "$PUBLISHED_AFTER"
ATTESTED=0
for attempt in 1 2 3; do
    if GH_PAGER=cat gh attestation verify "$WORK/public/$ARCHIVE_NAME" \
        --repo "$TAP_REPO" \
        --signer-workflow "$TAP_REPO/.github/workflows/release-attestation.yml" \
        >/dev/null; then
        ATTESTED=1
        break
    fi
    sleep $((attempt * 2))
done
[[ "$ATTESTED" == 1 ]] || die "the archive's attestation does not verify; the release is published but the cask is not"

# --- 5. Cask

if [[ -n "$(git -C "$TAP_DIR" status --porcelain -- Casks/fanmac.rb)" ]]; then
    git -C "$TAP_DIR" add Casks/fanmac.rb
    git -C "$TAP_DIR" commit --quiet -m "Publish FanMac v$VERSION"
fi
# An earlier run may have committed the cask and failed to push it.
git -C "$TAP_DIR" fetch --quiet origin main
if git -C "$TAP_DIR" merge-base --is-ancestor HEAD origin/main; then
    printf '==> The tap already has this cask\n'
    CASK_PUBLISHED=1
else
    printf '==> Publishing the cask\n'
    for attempt in 1 2 3; do
        if git -C "$TAP_DIR" push --quiet origin HEAD:main; then
            CASK_PUBLISHED=1
            break
        fi
        (( attempt < 3 )) || break
        git -C "$TAP_DIR" pull --quiet --rebase origin main || {
            git -C "$TAP_DIR" rebase --abort || true
            break
        }
    done
    [[ "$CASK_PUBLISHED" == 1 ]] || \
        die "could not push the cask; it is committed in $TAP_DIR, so push it from there"
fi

printf '\nFanMac %s is released.\n' "$VERSION"
printf 'Release: https://github.com/%s/releases/tag/%s\n' "$TAP_REPO" "$RELEASE_TAG"
printf 'SHA-256: %s\n' "$SHA256"
printf 'Install: brew install --cask fanmac\n'
