#!/usr/bin/env bash
# Build Dazey X into an .ipa.
#
#   ./build_ipa.sh                     signed, method from ExportOptions.plist (development)
#   ./build_ipa.sh --method ad-hoc     signed, override export method (development|ad-hoc|app-store)
#   ./build_ipa.sh --unsigned          unsigned .ipa for Sideloadly / AltStore
#
# Values below can also be passed as env vars: DEVELOPMENT_TEAM=ABCDE12345 ./build_ipa.sh
set -euo pipefail

# ---- Configure here ---------------------------------------------------------
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"            # 10-char Team ID, e.g. ABCDE12345
BUNDLE_ID="${BUNDLE_ID:-com.bossing.dazeyx}"
# -----------------------------------------------------------------------------

SCHEME="DazeyX"
CONFIGURATION="Release"
PROJECT="DazeyX.xcodeproj"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/DazeyX.xcarchive"

UNSIGNED=0
METHOD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --unsigned) UNSIGNED=1; shift ;;
    --method)   METHOD="${2:?--method needs a value}"; shift 2 ;;
    -h|--help)  sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

cd "$(dirname "$0")"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
elif [[ ! -d "$PROJECT" ]]; then
  echo "error: $PROJECT not found and xcodegen is not installed (brew install xcodegen)" >&2
  exit 1
fi

rm -rf "$ARCHIVE_PATH" "$BUILD_DIR/export" "$BUILD_DIR/Payload"
mkdir -p "$BUILD_DIR"

if [[ $UNSIGNED -eq 1 ]]; then
  echo "==> Archiving (unsigned)"
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=iOS' \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY=""

  APP_PATH="$ARCHIVE_PATH/Products/Applications/DazeyX.app"
  [[ -d "$APP_PATH" ]] || { echo "error: $APP_PATH not found" >&2; exit 1; }

  echo "==> Packaging Payload/DazeyX.app"
  mkdir -p "$BUILD_DIR/Payload"
  cp -R "$APP_PATH" "$BUILD_DIR/Payload/"
  rm -f "$BUILD_DIR/DazeyX-unsigned.ipa"
  (cd "$BUILD_DIR" && zip -qry DazeyX-unsigned.ipa Payload)
  rm -rf "$BUILD_DIR/Payload"

  echo "==> Done: $BUILD_DIR/DazeyX-unsigned.ipa (sign it with Sideloadly / AltStore)"
  exit 0
fi

if [[ -z "$DEVELOPMENT_TEAM" ]]; then
  echo "error: set DEVELOPMENT_TEAM at the top of build_ipa.sh (or use --unsigned)" >&2
  exit 1
fi

echo "==> Archiving (team $DEVELOPMENT_TEAM, bundle id $BUNDLE_ID)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGN_STYLE=Automatic

EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
cp ExportOptions.plist "$EXPORT_PLIST"
/usr/libexec/PlistBuddy -c "Set :teamID $DEVELOPMENT_TEAM" "$EXPORT_PLIST"
if [[ -n "$METHOD" ]]; then
  /usr/libexec/PlistBuddy -c "Set :method $METHOD" "$EXPORT_PLIST"
fi

echo "==> Exporting ($(/usr/libexec/PlistBuddy -c 'Print :method' "$EXPORT_PLIST"))"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$BUILD_DIR/export" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates

mv -f "$BUILD_DIR/export/DazeyX.ipa" "$BUILD_DIR/DazeyX.ipa"
echo "==> Done: $BUILD_DIR/DazeyX.ipa"
