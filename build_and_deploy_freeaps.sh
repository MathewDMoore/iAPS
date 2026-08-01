#!/usr/bin/env bash
set -euo pipefail

# --- Required environment variables (fail fast) ---
: "${TEAM_ID:?Set TEAM_ID (Apple Developer Team ID, 10 chars)}"
: "${DEVICE_UDID:?Set DEVICE_UDID (your iPhone UDID)}"
: "${ROOT_BUNDLE:?Set ROOT_BUNDLE (e.g. com.yourdomain.FreeAPS)}"

# --- Derived values and defaults ---
APP_BUNDLE_ID="${APP_BUNDLE_ID:-$ROOT_BUNDLE}"
WATCH_BUNDLE_ID="${WATCH_BUNDLE_ID:-$ROOT_BUNDLE.watch}"
WATCH_EXT_BUNDLE_ID="${WATCH_EXT_BUNDLE_ID:-$ROOT_BUNDLE.watch.extension}"
LIVE_BUNDLE_ID="${LIVE_BUNDLE_ID:-$ROOT_BUNDLE.liveactivity}"
SCHEME="${SCHEME:-FreeAPS}"
CONFIG="${CONFIG:-Debug}"
DERIVED="${DERIVED:-$(pwd)/build/FreeAPSDerived}"
IOS_ONLY="${IOS_ONLY:-0}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-4}"

cat <<EOF

=== Build configuration ===
TEAM_ID:               $TEAM_ID
DEVICE_UDID:           $DEVICE_UDID
App bundle:            $APP_BUNDLE_ID
Watch app bundle:      $WATCH_BUNDLE_ID
Watch ext bundle:      $WATCH_EXT_BUNDLE_ID
LiveActivity bundle:   $LIVE_BUNDLE_ID
Scheme:                $SCHEME
Configuration:         $CONFIG
DerivedData:           $DERIVED
IOS_ONLY (skip watch/live): $IOS_ONLY
MAX_ATTEMPTS:          $MAX_ATTEMPTS
===========================
EOF

# --- Common xcodebuild flags ---
COMMON_FLAGS=(
  -configuration "$CONFIG"
  -derivedDataPath "$DERIVED"
  -allowProvisioningUpdates
  CODE_SIGN_STYLE=Automatic
  DEVELOPMENT_TEAM="$TEAM_ID"
  PROVISIONING_PROFILE_SPECIFIER=""
)

clean_derived() {
  echo "Cleaning derived data at $DERIVED"
  rm -rf "$DERIVED"
}

seed_signing() {
  # Seed Live Activity
  echo "Seeding automatic signing for LiveActivityExtension…"
  if ! xcodebuild -target LiveActivityExtension -destination "generic/platform=iOS" "${COMMON_FLAGS[@]}" PRODUCT_BUNDLE_IDENTIFIER="$LIVE_BUNDLE_ID" clean build ; then
    echo "[WARN] LiveActivityExtension seed build failed — continuing."
  fi

  # Seed Watch app
  echo "Seeding automatic signing for FreeAPSWatch (watch app)…"
  if ! xcodebuild -target FreeAPSWatch -destination "generic/platform=watchOS" "${COMMON_FLAGS[@]}" PRODUCT_BUNDLE_IDENTIFIER="$WATCH_BUNDLE_ID" clean build ; then
    echo "[WARN] FreeAPSWatch seed build failed — continuing."
  fi

  # Seed Watch extension if present
  if xcodebuild -list -json | grep -q 'FreeAPSWatch Extension'; then
    echo "Seeding automatic signing for FreeAPSWatch Extension…"
    if ! xcodebuild -target "FreeAPSWatch Extension" -destination "generic/platform=watchOS" "${COMMON_FLAGS[@]}" PRODUCT_BUNDLE_IDENTIFIER="$WATCH_EXT_BUNDLE_ID" clean build ; then
      echo "[WARN] FreeAPSWatch Extension seed build failed — continuing."
    fi
  fi
}

build_ios_target() {
  echo "Building iOS app target FreeAPS for device…"
  xcodebuild -target FreeAPS -destination "platform=iOS,id=$DEVICE_UDID" "${COMMON_FLAGS[@]}" PRODUCT_BUNDLE_IDENTIFIER="$APP_BUNDLE_ID" clean build
}

build_scheme_all() {
  echo "Building app scheme $SCHEME for device (includes watch/live if configured)…"
  xcodebuild -scheme "$SCHEME" -destination "platform=iOS,id=$DEVICE_UDID" "${COMMON_FLAGS[@]}" PRODUCT_BUNDLE_IDENTIFIER="$APP_BUNDLE_ID" clean build
}

locate_app() {
  local path
  path=$(find "$DERIVED/Build/Products/$CONFIG-iphoneos" -maxdepth 1 -type d -name "*.app" | head -n 1 || true)
  if [[ -z "${path:-}" ]]; then
    echo "ERROR: Built .app not found in $DERIVED/Build/Products/$CONFIG-iphoneos"
    return 1
  fi
  echo "$path"
}

install_and_launch() {
  local app_path="$1"
  if command -v xcrun >/dev/null 2>&1 && xcrun devicectl --help >/dev/null 2>&1; then
    echo "Installing to device $DEVICE_UDID…"
    xcrun devicectl device install app --device "$DEVICE_UDID" "$app_path"
    echo "Launching $APP_BUNDLE_ID…"
    xcrun devicectl device process launch --device "$DEVICE_UDID" "$APP_BUNDLE_ID"
  else
    echo "[INFO] devicectl not available. Skipping install/launch. Install via Xcode or Apple Configurator."
  fi
}

should_seed() {
  [[ "$IOS_ONLY" != "1" ]]
}

attempt_build_with_repairs() {
  local attempt=1
  local last_error=""

  while (( attempt <= MAX_ATTEMPTS )); do
    echo "\n=== Attempt $attempt/$MAX_ATTEMPTS ==="

    clean_derived

    if should_seed; then
      seed_signing || true
    fi

    set +e
    if [[ "$IOS_ONLY" == "1" ]]; then
      build_ios_target
    else
      build_scheme_all
    fi
    status=$?
    set -e

    if [[ $status -eq 0 ]]; then
      echo "Build succeeded on attempt $attempt."
      return 0
    fi

    echo "Build failed on attempt $attempt with status $status. Applying repairs…"

    # Repair strategy by attempt number
    case "$attempt" in
      1)
        echo "[Repair] Re-seed signing and retry with scheme build."
        IOS_ONLY=0
        ;;
      2)
        echo "[Repair] Switch to iOS-only target build to isolate watch/live issues."
        IOS_ONLY=1
        ;;
      3)
        echo "[Repair] Full clean + re-seed + switch configuration to Release."
        CONFIG=Release
        COMMON_FLAGS=(
          -configuration "$CONFIG"
          -derivedDataPath "$DERIVED"
          -allowProvisioningUpdates
          CODE_SIGN_STYLE=Automatic
          DEVELOPMENT_TEAM="$TEAM_ID"
          PROVISIONING_PROFILE_SPECIFIER=""
        )
        ;;
      *)
        echo "No more automated repairs available."
        ;;
    esac

    ((attempt++))
  done

  echo "ERROR: Build failed after $MAX_ATTEMPTS attempts."
  return 1
}

# --- Orchestrate build with self-healing ---
attempt_build_with_repairs

# --- Locate and install if built ---
APP_PATH=$(locate_app)
echo "Built app at: $APP_PATH"
install_and_launch "$APP_PATH"

echo "Done."
