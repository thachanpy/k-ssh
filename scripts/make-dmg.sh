#!/usr/bin/env bash
# Builds K-SSH (Release, ad-hoc signed) and packs it into build/K-SSH.dmg.
#
# Usage:  scripts/make-dmg.sh [--version 0.1.0] [--sign "Apple Development: Name (TEAMID)"]
#
# Default signing is ad-hoc ("-"): the app runs, but other Macs show an "unidentified developer"
# warning (see the instructions file packed inside the DMG). Passing --sign uses your certificate instead.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="K-SSH"
PRODUCT="SSHClient"                     # build product name (module/target) — kept internal
IDENTITY="-"
VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) IDENTITY="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v xcodegen >/dev/null || { echo "xcodegen not found (brew install xcodegen)" >&2; exit 1; }

BUILD_DIR="$PWD/build"
DERIVED="$BUILD_DIR/DerivedData"
STAGE="$BUILD_DIR/dmg"
rm -rf "$DERIVED" "$STAGE"
mkdir -p "$STAGE"

echo "==> Generating Xcode project"
xcodegen generate

EXTRA=()
[[ -n "$VERSION" ]] && EXTRA+=("MARKETING_VERSION=$VERSION")

echo "==> Building Release (signing identity: $IDENTITY)"
xcodebuild -project "$PRODUCT.xcodeproj" -scheme "$PRODUCT" -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" -skipPackagePluginValidation \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGNING_REQUIRED=YES \
  DEVELOPMENT_TEAM="" ${EXTRA[@]+"${EXTRA[@]}"} \
  build

BUILT="$DERIVED/Build/Products/Release/$PRODUCT.app"
[[ -d "$BUILT" ]] || { echo "Build output not found: $BUILT" >&2; exit 1; }

echo "==> Preparing $APP_NAME.app"
cp -R "$BUILT" "$STAGE/$APP_NAME.app"
xattr -cr "$STAGE/$APP_NAME.app"
# Renaming the bundle folder keeps the signature valid, so the build's own signing (incl. sandbox
# entitlements) is left untouched.
codesign --verify --deep --strict "$STAGE/$APP_NAME.app"
echo "Entitlements:"; codesign -d --entitlements - "$STAGE/$APP_NAME.app" 2>/dev/null | grep -E "app-sandbox|network|files|bookmarks" || true

ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to open K-SSH.txt" <<'TXT'
K-SSH is not notarized by Apple, so macOS may block the first launch.

1. Drag K-SSH into Applications.
2. Right-click K-SSH → Open → Open (only needed the first time).

If macOS still says the app is damaged or cannot be opened, run in Terminal:
    xattr -dr com.apple.quarantine /Applications/K-SSH.app
TXT

echo "==> Creating DMG"
DMG="$BUILD_DIR/$APP_NAME.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo
echo "Done: $DMG"
shasum -a 256 "$DMG"
