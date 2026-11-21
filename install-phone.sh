#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

: "${DEVICECTL_DEVICE_ID:?Set DEVICECTL_DEVICE_ID to the target from xcrun devicectl list devices.}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-build/DerivedData}"
CONFIGURATION="${CONFIGURATION:-Debug}"
APP_NAME="${APP_NAME:-RepoPromptRemote}"
BUNDLE_ID="${BUNDLE_ID:-com.repoprompt.remote}"
APP_PATH="${APP_PATH:-$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION-iphoneos/$APP_NAME.app}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  echo "Run ./build-phone.sh first, or set APP_PATH to an existing .app bundle." >&2
  exit 1
fi

xcrun devicectl device install app \
  --device "$DEVICECTL_DEVICE_ID" \
  "$APP_PATH"

xcrun devicectl device process launch \
  --device "$DEVICECTL_DEVICE_ID" \
  --terminate-existing \
  "$BUNDLE_ID"
