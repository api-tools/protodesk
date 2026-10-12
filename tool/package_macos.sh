#!/bin/sh
# Sign nested code inside-out, retain the sandbox, verify, and archive the full app.
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TASK_APP="$TASK_ROOT/build/macos/Build/Products/Release/ProtoDesk.app"
TASK_IDENTITY="${PROTODESK_SIGNING_IDENTITY:--}"
/usr/bin/codesign --force --sign "$TASK_IDENTITY" --entitlements "$TASK_ROOT/macos/Runner/Protoc.entitlements" "$TASK_APP/Contents/Helpers/protoc"
for TASK_FRAMEWORK in "$TASK_APP"/Contents/Frameworks/*.framework; do
  /usr/bin/codesign --force --sign "$TASK_IDENTITY" "$TASK_FRAMEWORK"
done
/usr/bin/codesign --force --sign "$TASK_IDENTITY" --entitlements "$TASK_ROOT/macos/Runner/Release.entitlements" "$TASK_APP"
/usr/bin/codesign --verify --deep --strict "$TASK_APP"
mkdir -p "$TASK_ROOT/dist"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$TASK_APP" "$TASK_ROOT/dist/ProtoDesk-macos-universal.zip"
