#!/bin/bash
# Builds a release of iOS Developer Toolkit, locally or in CI. Needs Xcode, plus autoconf,
# automake, libtool, pkg-config, and cmake for the firmware helpers (see
# scripts/build-restore-helpers.sh; a build is reused while that script is unchanged).
#
#   scripts/build-release.sh [VERSION] [OUTPUT_DIR]
#
# VERSION defaults to ToolkitVersion.current and must match it and MARKETING_VERSION in
# project.yml. OUTPUT_DIR defaults to build-output/release/VERSION (replaced on each run); any
# other OUTPUT_DIR must be empty or absent.
#
# Produces, in OUTPUT_DIR:
#   iOS-Developer-Toolkit-Swift-VERSION-macOS-universal.zip  the app (arm64 + x86_64), ad-hoc signed
#                                                      with the hardened runtime; idt is at
#                                                      Contents/MacOS/idt, the firmware helpers
#                                                      (idevicerestore, irecovery) are in
#                                                      Contents/Helpers, and dependency licenses,
#                                                      notices, and the SBOM are in
#                                                      Contents/Resources/Licenses
#   iOS-Developer-Toolkit-Swift-VERSION.spdx.json            SPDX 2.3 SBOM from Package.resolved
#   iOS-Developer-Toolkit-Swift-VERSION-firmware-helpers-source.tar.gz
#                                                      the complete source of the bundled firmware
#                                                      helpers and the script that builds them
#   SHA256SUMS.txt                                     checksums of these files
set -euo pipefail

fail() { echo "build-release: $*" >&2; exit 1; }
step() { echo "==> $*"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

current="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/ToolkitCore/ToolkitVersion.swift)"
marketing="$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)"
VERSION="${1:-$current}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 1.2.3 (got '$VERSION')"
[[ "$VERSION" == "$current" ]] || fail "version $VERSION does not match ToolkitVersion.current ($current)"
[[ "$VERSION" == "$marketing" ]] || fail "version $VERSION does not match MARKETING_VERSION in project.yml ($marketing)"

COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ "$COMMIT" != unknown && -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    echo "build-release: warning: the working tree has uncommitted changes; the SBOM records $COMMIT-dirty" >&2
    COMMIT="$COMMIT-dirty"
fi

DEFAULT_OUT="$ROOT/build-output/release/$VERSION"
OUT="${2:-$DEFAULT_OUT}"
if [[ "$OUT" == "$DEFAULT_OUT" ]]; then
    rm -rf "$OUT"
elif [[ -e "$OUT" && -n "$(ls -A "$OUT")" ]]; then
    fail "$OUT is not empty"
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

CACHE="$ROOT/build-output/release-cache"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/idt-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
DERIVED_DATA="$WORK/DerivedData"

NAME="iOS-Developer-Toolkit-Swift-$VERSION"
ZIP="$OUT/$NAME-macOS-universal.zip"
SBOM="$OUT/$NAME.spdx.json"
HELPER_SOURCE="$OUT/$NAME-firmware-helpers-source.tar.gz"
ENTITLEMENTS="App/iOSDeveloperToolkit/iOSDeveloperToolkit.entitlements"

step "Xcode: $(xcodebuild -version | tr '\n' ' ')"

step "Archiving the app (arm64 + x86_64, Release)"
xcodebuild -project iOSDeveloperToolkit.xcodeproj -scheme iOSDeveloperToolkit \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" -archivePath "$WORK/app.xcarchive" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    -quiet archive
APP="$WORK/app.xcarchive/Products/Applications/iOS Developer Toolkit (Swift).app"
[[ -d "$APP" ]] || fail "the archive does not contain the app"

step "Building idt (arm64 + x86_64, release)"
if ! swift build -c release --product idt --arch arm64 --arch x86_64 --scratch-path "$CACHE/spm" > "$WORK/idt-build.log" 2>&1; then
    grep -E "error:|warning:" "$WORK/idt-build.log" | sort -u | head -40 >&2
    tail -40 "$WORK/idt-build.log" >&2
    fail "the universal idt build failed (output above)"
fi
BIN="$(swift build -c release --product idt --arch arm64 --arch x86_64 --scratch-path "$CACHE/spm" --show-bin-path)"
cp "$BIN/idt" "$APP/Contents/MacOS/idt"

step "Firmware helpers (idevicerestore, irecovery)"
HELPERS="$ROOT/build-output/restore-helpers/out"
helper_stamp="$(shasum -a 256 scripts/build-restore-helpers.sh | cut -d' ' -f1)"
if [[ "$(cat "$HELPERS/STAMP" 2>/dev/null)" != "$helper_stamp" ]]; then
    if ! scripts/build-restore-helpers.sh "$HELPERS" > "$WORK/helpers-build.log" 2>&1; then
        tail -60 "$WORK/helpers-build.log" >&2
        fail "the firmware helpers did not build (output above)"
    fi
fi
# The helpers' complete source, as the LGPL asks of anyone distributing them.
HELPER_SRC="$ROOT/build-output/restore-helpers/src"
mkdir -p "$WORK/helper-source/firmware-helpers-source"
for repo in "$HELPER_SRC"/*/.git; do
    name="$(basename "$(dirname "$repo")")"
    git -C "$HELPER_SRC/$name" archive --format=tar --prefix="$name/" HEAD | tar -x -C "$WORK/helper-source/firmware-helpers-source"
done
cp "$HELPER_SRC"/openssl-*.tar.gz scripts/build-restore-helpers.sh "$HELPERS/SOURCES.txt" "$WORK/helper-source/firmware-helpers-source/"
tar -czf "$HELPER_SOURCE" -C "$WORK/helper-source" firmware-helpers-source
mkdir -p "$APP/Contents/Helpers"
for helper in idevicerestore irecovery; do
    cp "$HELPERS/bin/$helper" "$APP/Contents/Helpers/$helper"
done

step "Adding licenses, notices, and the SBOM"
LICENSES="$APP/Contents/Resources/Licenses"
mkdir -p "$LICENSES"
cp LICENSE "$LICENSES/LICENSE-iOS-Developer-Toolkit.txt"
cp THIRD_PARTY_NOTICES.md SOURCE_AVAILABILITY.md "$LICENSES/"
for identity in $(sed -n 's/.*"identity" : "\(.*\)".*/\1/p' Package.resolved); do
    checkout="$CACHE/spm/checkouts/$identity"
    [[ -d "$checkout" ]] || fail "missing checkout for $identity"
    mkdir -p "$LICENSES/$identity"
    found=0
    for file in "$checkout"/LICENSE* "$checkout"/NOTICE*; do
        [[ -f "$file" ]] || continue
        cp "$file" "$LICENSES/$identity/"
        found=1
    done
    [[ "$found" == 1 ]] || fail "no license file found for $identity"
done
mkdir -p "$LICENSES/restore-helpers"
cp -R "$HELPERS/licenses/." "$LICENSES/restore-helpers/"
cp "$HELPERS/SOURCES.txt" "$LICENSES/restore-helpers/SOURCES.txt"
xcrun swift scripts/generate-sbom.swift Package.resolved "$CACHE/spm/checkouts" "$VERSION" "$COMMIT" "$SBOM"
cp "$SBOM" "$LICENSES/sbom.spdx.json"

step "Signing (ad hoc, hardened runtime)"
codesign --force --sign - --options runtime --timestamp=none \
    --identifier io.hideouts.iOSDeveloperToolkit.idt "$APP/Contents/MacOS/idt"
for helper in idevicerestore irecovery; do
    codesign --force --sign - --options runtime --timestamp=none \
        --identifier "io.hideouts.iOSDeveloperToolkit.$helper" "$APP/Contents/Helpers/$helper"
done
codesign --force --sign - --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" "$APP"

# The libraries a binary links. otool reads a path ending in "(…)" as an archive member, so the
# app's executable ("… (Swift)") is read through a link with a plain name.
linked_libraries() {
    local link="$WORK/otool-target"
    ln -sf "$1" "$link"
    otool -L "$link" | grep -v ':$' | awk '{print $1}'
    rm -f "$link"
}

verify_app() {
    local app="$1"
    codesign --verify --deep --strict "$app" || fail "codesign verification failed for $app"
    local details
    for binary in "$app/Contents/MacOS/iOS Developer Toolkit (Swift)" "$app/Contents/MacOS/idt" "$app/Contents/Helpers/idevicerestore" "$app/Contents/Helpers/irecovery"; do
        details="$(codesign --display --verbose=2 "$binary" 2>&1)"
        grep -q 'Signature=adhoc' <<<"$details" || fail "$(basename "$binary") is not ad-hoc signed"
        grep -Eq 'flags=0x[0-9a-f]+\(.*runtime' <<<"$details" || fail "$(basename "$binary") lacks the hardened runtime"
        local archs
        archs="$(lipo -archs "$binary")"
        [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || fail "$(basename "$binary") is not universal ($archs)"
        local libraries
        libraries="$(linked_libraries "$binary")" || fail "otool could not read $(basename "$binary")"
        [[ -n "$libraries" ]] || fail "otool listed no libraries for $(basename "$binary")"
        if grep -qi python <<<"$libraries"; then fail "$(basename "$binary") links Python"; fi
        if grep -Eq '^(/opt/homebrew|/usr/local)/' <<<"$libraries"; then fail "$(basename "$binary") links a Homebrew library"; fi
    done
    local plist_version
    plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
    [[ "$plist_version" == "$VERSION" ]] || fail "Info.plist version is $plist_version, expected $VERSION"
    local idt_version
    idt_version="$("$app/Contents/MacOS/idt" --version)"
    [[ "$idt_version" == "$VERSION" ]] || fail "idt reports $idt_version, expected $VERSION"
    if [[ "$(uname -m)" == arm64 ]] && arch -x86_64 /usr/bin/true 2>/dev/null; then
        [[ "$(arch -x86_64 "$app/Contents/MacOS/idt" --version)" == "$VERSION" ]] || fail "the x86_64 slice of idt does not run"
        arch -x86_64 "$app/Contents/Helpers/idevicerestore" --version | grep -q '^idevicerestore ' || fail "the x86_64 slice of idevicerestore does not run"
    fi
    [[ -f "$app/Contents/Resources/Licenses/swift-nio-ssl/NOTICE.txt" ]] || fail "license notices are missing"
    [[ -f "$app/Contents/Resources/Licenses/restore-helpers/idevicerestore/COPYING" && -f "$app/Contents/Resources/Licenses/restore-helpers/SOURCES.txt" ]] \
        || fail "the firmware helpers' licenses are missing"
    "$app/Contents/Helpers/idevicerestore" --version | grep -q '^idevicerestore ' || fail "idevicerestore does not run"
    "$app/Contents/Helpers/irecovery" --version | grep -q '^irecovery ' || fail "irecovery does not run"
}

step "Verifying the signed app"
verify_app "$APP"

step "Packaging"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$SBOM")" "$(basename "$HELPER_SOURCE")" > SHA256SUMS.txt)

step "Verifying the ZIP"
mkdir "$WORK/unzipped"
ditto -x -k "$ZIP" "$WORK/unzipped"
verify_app "$WORK/unzipped/iOS Developer Toolkit (Swift).app"
(cd "$OUT" && shasum -a 256 -c SHA256SUMS.txt)

step "Done: $OUT"
ls -l "$OUT"
