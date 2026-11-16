#!/usr/bin/env bash
set -euo pipefail

DERIVED_DATA_DIR="${1:-build/DerivedData}"
OUTPUT_DIR="${2:-dist}"

APP_PATH=$(find "$DERIVED_DATA_DIR/Build/Products" -name "JellyfinDesktop.app" -path "*Release-iphoneos*" | head -n 1)
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "ERROR: JellyfinDesktop.app not found under $DERIVED_DATA_DIR/Build/Products"
  exit 1
fi

echo "==> Found built app: $APP_PATH"

# Verify WebResources folder reference was copied intact
if [[ ! -f "$APP_PATH/WebResources/find-webclient.html" || ! -f "$APP_PATH/WebResources/extension/nativeshell.js" ]]; then
  echo "ERROR: WebResources directory is missing inside $APP_PATH"
  ls -la "$APP_PATH"
  exit 1
fi

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

mkdir -p "$STAGE_DIR/Payload"
cp -R "$APP_PATH" "$STAGE_DIR/Payload/JellyfinDesktop.app"
STAGED_APP="$STAGE_DIR/Payload/JellyfinDesktop.app"

# Locate MobileVLCKit binary from Pods to verify static vs dynamic linkage
VLC_POD_FW=$(find Pods -path "*ios-arm64*/MobileVLCKit.framework" -not -path "*simulator*" | head -n 1 || true)
if [[ -n "$VLC_POD_FW" && -f "$VLC_POD_FW/MobileVLCKit" ]]; then
  VLC_FILE_INFO=$(file "$VLC_POD_FW/MobileVLCKit")
  echo "==> MobileVLCKit binary type: $VLC_FILE_INFO"

  if echo "$VLC_FILE_INFO" | grep -q "dynamically linked shared library"; then
    mkdir -p "$STAGED_APP/Frameworks"
    if [[ ! -d "$STAGED_APP/Frameworks/MobileVLCKit.framework" ]]; then
      echo "==> Copying dynamic MobileVLCKit.framework into Frameworks/"
      cp -R "$VLC_POD_FW" "$STAGED_APP/Frameworks/MobileVLCKit.framework"
    fi
    # Thin to arm64 only if fat binary (saves ~40 MB on iPad Air 2)
    EMBEDDED_BIN="$STAGED_APP/Frameworks/MobileVLCKit.framework/MobileVLCKit"
    if lipo -info "$EMBEDDED_BIN" 2>/dev/null | grep -q "Architectures in the fat file"; then
      if lipo -archs "$EMBEDDED_BIN" | grep -qw "arm64"; then
        echo "==> Thinning MobileVLCKit to arm64..."
        lipo "$EMBEDDED_BIN" -thin arm64 -output "${EMBEDDED_BIN}.arm64"
        mv "${EMBEDDED_BIN}.arm64" "$EMBEDDED_BIN"
      fi
    fi
  elif echo "$VLC_FILE_INFO" | grep -q "ar archive"; then
    echo "==> MobileVLCKit is statically linked; ensuring no static archive remains in Frameworks/"
    rm -rf "$STAGED_APP/Frameworks/MobileVLCKit.framework"
    rmdir "$STAGED_APP/Frameworks" 2>/dev/null || true
  fi
fi

# Strip any leftover simulator slices or header/module files inside embedded frameworks
if [[ -d "$STAGED_APP/Frameworks" ]]; then
  for fw in "$STAGED_APP/Frameworks"/*.framework; do
    [[ -d "$fw" ]] || continue
    rm -rf "$fw/Headers" "$fw/PrivateHeaders" "$fw/Modules"
    echo "==> Ad-hoc signing embedded framework: $(basename "$fw")"
    /usr/bin/codesign --force --sign - --timestamp=none "$fw"
  done
fi

echo "==> Ad-hoc signing JellyfinDesktop.app..."
/usr/bin/codesign --force --sign - --timestamp=none "$STAGED_APP"

mkdir -p "$OUTPUT_DIR"
IPA_PATH="$OUTPUT_DIR/JellyfinDesktop-iOS15-unsigned.ipa"
TIPA_PATH="$OUTPUT_DIR/JellyfinDesktop-iOS15-TrollStore.tipa"

rm -f "$IPA_PATH" "$TIPA_PATH"
(
  cd "$STAGE_DIR"
  ditto -c -k --sequesterRsrc --keepParent Payload "$OLDPWD/$IPA_PATH"
)
cp "$IPA_PATH" "$TIPA_PATH"

echo "==> Packaged IPA successfully:"
ls -lh "$IPA_PATH" "$TIPA_PATH"
