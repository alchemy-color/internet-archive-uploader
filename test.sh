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
  test
