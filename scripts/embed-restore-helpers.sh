#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPERS="$ROOT/build-output/restore-helpers/out"
STAGING="$(mktemp -d "$TEMP_DIR/firmware-helpers.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

DESTINATION="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME/Contents/Helpers"
mkdir -p "$DESTINATION"
for helper in idevicerestore irecovery; do
    SOURCE="$HELPERS/bin/$helper"
    [[ -x "$SOURCE" ]] || { echo "Missing executable firmware helper: $SOURCE. Build the FirmwareHelpers target first." >&2; exit 1; }
    # install and codesign create temporary files. Use Xcode's writable staging
    # directory, then copy only the declared final output into the app bundle.
    install -m 755 "$SOURCE" "$STAGING/$helper"
    if [[ "$CODE_SIGNING_ALLOWED" == YES ]]; then
        codesign --force --sign "$CODE_SIGN_IDENTITY" --options runtime --timestamp=none \
            --identifier "io.hideouts.iOSDeveloperToolkit.$helper" "$STAGING/$helper"
    fi
    cp "$STAGING/$helper" "$DESTINATION/$helper"
    chmod 755 "$DESTINATION/$helper"
done

LICENSE_DESTINATION="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME/Contents/Resources/Licenses/restore-helpers"
mkdir -p "$LICENSE_DESTINATION"
cp -R "$HELPERS/licenses/." "$LICENSE_DESTINATION/"
cp "$HELPERS/SOURCES.txt" "$LICENSE_DESTINATION/SOURCES.txt"
