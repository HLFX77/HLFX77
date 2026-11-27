#!/usr/bin/env bash
set -euo pipefail

# Compiles LANScreen for physical iOS devices (arm64) without signing and packages Payload/LANScreen.app into LANScreen-unsigned.ipa.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Erreur : macOS et Xcode sont requis pour compiler un fichier .ipa."
  exit 1
fi

DERIVED_DATA="$ROOT_DIR/build/DerivedData"
IPA_DIR="$ROOT_DIR/build/ipa"
PAYLOAD_DIR="$IPA_DIR/Payload"
OUTPUT_IPA="$IPA_DIR/LANScreen-unsigned.ipa"

rm -rf "$DERIVED_DATA" "$IPA_DIR"
mkdir -p "$PAYLOAD_DIR"

xcodebuild build \
  -project LANScreen.xcodeproj \
  -scheme LANScreen \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/LANScreen.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Erreur : LANScreen.app introuvable à $APP_PATH"
  exit 1
fi

cp -R "$APP_PATH" "$PAYLOAD_DIR/"
(cd "$IPA_DIR" && zip -qry "$(basename "$OUTPUT_IPA")" Payload)
rm -rf "$PAYLOAD_DIR"

echo "IPA non signé généré : $OUTPUT_IPA"
ls -lh "$OUTPUT_IPA"
