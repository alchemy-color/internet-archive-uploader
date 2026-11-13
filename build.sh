#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
# Build outside iCloud Drive / the source folder; override with DERIVED=...
DERIVED="${DERIVED:-${TMPDIR:-/tmp}/ia-uploader-dd}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

"$DEVELOPER_DIR/usr/bin/xcodebuild" \
  -project IAUploader.xcodeproj \
  -scheme IAUploader \
  -configuration "${CONFIGURATION:-Debug}" \
  -derivedDataPath "$DERIVED" \
  build

APP_SRC="$DERIVED/Build/Products/${CONFIGURATION:-Debug}/ArchiveUploader.app"
APP_DST="$(pwd)/ArchiveUploader.app"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
xattr -cr "$APP_DST"
echo "Built and copied to $APP_DST"
