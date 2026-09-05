#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

source "$ROOT/version.env"
source "$ROOT/Scripts/release_artifacts.sh"

ARCHES_VALUE="${ARCHES:-arm64 x86_64}"
DIST_DIR="${CODEXBAR_FORKFIX_DIST_DIR:-$ROOT/dist}"
TEMP_PARENT="${TMPDIR:-/tmp}"
TEMP_PARENT="${TEMP_PARENT%/}"
WORK_ROOT=$(mktemp -d "$TEMP_PARENT/codexbar-forkfix-package.XXXXXX")
APP_OUTPUT_DIR="$WORK_ROOT/output"
APP_STAGE_DIR="$WORK_ROOT/package"
APP_NAME="CodexBar ForkFix"
BUNDLE_ID="com.hyosungsink.codexbar.forkfix"
PORTABLE_CACHE_ROOT='~/Library/Caches/CodexBarForkFix'
ARCH_LABEL=$(codexbar_release_arch_label "$ARCHES_VALUE")
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
PACKAGE_VERSION="${MARKETING_VERSION}-forkfix.${GIT_COMMIT}"
ARCHIVE_NAME="CodexBar-ForkFix-${ARCH_LABEL}-${PACKAGE_VERSION}.zip"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

cleanup() {
  case "$WORK_ROOT" in
    "$TEMP_PARENT"/codexbar-forkfix-package.*)
      [[ -d "$WORK_ROOT" ]] && rm -rf -- "$WORK_ROOT"
      ;;
    *)
      echo "WARN: Refusing to clean unexpected temporary path: $WORK_ROOT" >&2
      ;;
  esac
}
trap cleanup EXIT

mkdir -p "$APP_OUTPUT_DIR" "$APP_STAGE_DIR" "$DIST_DIR"

env \
  ARCHES="$ARCHES_VALUE" \
  CODEXBAR_SIGNING=adhoc \
  CODEXBAR_APP_BUNDLE_NAME="$APP_NAME" \
  CODEXBAR_APP_DISPLAY_NAME="$APP_NAME" \
  CODEXBAR_BUNDLE_ID="$BUNDLE_ID" \
  CODEXBAR_APP_OUTPUT_DIR="$APP_OUTPUT_DIR" \
  CODEXBAR_APP_STAGE_DIR="$APP_STAGE_DIR" \
  CODEXBAR_COST_CACHE_ROOT="$PORTABLE_CACHE_ROOT" \
  CODEXBAR_CODEX_CLI_ONLY=1 \
  CODEXBAR_REMOTE_CODEX_USAGE=1 \
  "$ROOT/Scripts/package_app.sh" release

APP_PATH="$APP_OUTPUT_DIR/$APP_NAME.app"
PLIST_PATH="$APP_PATH/Contents/Info.plist"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/CodexBar"

[[ -d "$APP_PATH" ]] || { echo "ERROR: Missing packaged app: $APP_PATH" >&2; exit 1; }
[[ -f "$PLIST_PATH" ]] || { echo "ERROR: Missing packaged Info.plist" >&2; exit 1; }

actual_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST_PATH")
actual_cache_root=$(/usr/libexec/PlistBuddy -c 'Print :CodexBarCostCacheRoot' "$PLIST_PATH")
actual_cli_only=$(/usr/libexec/PlistBuddy -c 'Print :CodexBarCodexCLIOnly' "$PLIST_PATH")
actual_remote_usage=$(/usr/libexec/PlistBuddy -c 'Print :CodexBarRemoteCodexUsageEnabled' "$PLIST_PATH")

[[ "$actual_bundle_id" == "$BUNDLE_ID" ]] || {
  echo "ERROR: Unexpected bundle identifier: $actual_bundle_id" >&2
  exit 1
}
[[ "$actual_cache_root" == "$PORTABLE_CACHE_ROOT" ]] || {
  echo "ERROR: Package contains a device-specific cache root: $actual_cache_root" >&2
  exit 1
}
[[ "$actual_cli_only" == "true" ]] || { echo "ERROR: CLI-only mode is disabled" >&2; exit 1; }
[[ "$actual_remote_usage" == "true" ]] || { echo "ERROR: Remote usage sync is disabled" >&2; exit 1; }

for arch in $ARCHES_VALUE; do
  lipo -archs "$EXECUTABLE_PATH" | tr ' ' '\n' | grep -qx "$arch" || {
    echo "ERROR: Packaged app is missing architecture: $arch" >&2
    exit 1
  }
done

BUILD_USER_HOME="${HOME:?}"
for local_path in "$ROOT" "$BUILD_USER_HOME"; do
  if LC_ALL=C grep -RlaF "$local_path" "$APP_PATH" >/dev/null 2>&1; then
    echo "ERROR: Packaged app contains a build-machine path: $local_path" >&2
    exit 1
  fi
done

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
(
  cd "$DIST_DIR"
  shasum -a 256 "$ARCHIVE_NAME" > "$(basename "$CHECKSUM_PATH")"
)

echo "Created $ARCHIVE_PATH"
echo "Created $CHECKSUM_PATH"
