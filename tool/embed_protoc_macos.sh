#!/bin/sh
set -eu
TASK_HELPER_DIR="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$TASK_HELPER_DIR"
cp "$PROJECT_DIR/../assets/protoc/bin/protoc" "$TASK_HELPER_DIR/protoc"
chmod 755 "$TASK_HELPER_DIR/protoc"
TASK_SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [ -z "$TASK_SIGNING_IDENTITY" ]; then TASK_SIGNING_IDENTITY=-; fi
/usr/bin/codesign --force --sign "$TASK_SIGNING_IDENTITY" --entitlements "$PROJECT_DIR/Runner/Protoc.entitlements" "$TASK_HELPER_DIR/protoc"
