#!/usr/bin/env bash
set -euo pipefail

# Build, unit-test, archive, and export a signed LANScreen.ipa on macOS with Xcode installed.
# Usage:
#   TEAM_ID=YOUR_APPLE_TEAM_ID ./scripts/build_ipa.sh
# Optional overrides:
#   BUNDLE_ID_PREFIX=com.yourdomain.lanscreen
#   EXPORT_METHOD=development   # or ad-hoc

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Erreur : ce script nécessite macOS avec Xcode (xcodebuild)."
  exit 1
fi

TEAM_ID="${TEAM_ID:-}"
BUNDLE_ID_PREFIX="${BUNDLE_ID_PREFIX:-com.lanscreen.app}"
BUILD_DIR="$ROOT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/LANScreen.xcarchive"
IPA_OUTPUT_DIR="$BUILD_DIR/ipa"

mkdir -p "$BUILD_DIR" "$IPA_OUTPUT_DIR"

if command -v xcodegen >/dev/null 2>&1; then
  echo "[1/4] Régénération du projet Xcode via XcodeGen..."
  xcodegen generate
else
  echo "[1/4] Utilisation du projet LANScreen.xcodeproj existant..."
fi

echo "[2/4] Résolution des dépendances Swift Package Manager (WebRTC)..."
xcodebuild -resolvePackageDependencies \
  -project LANScreen.xcodeproj \
  -scheme LANScreen

echo "[3/4] Exécution des tests unitaires sur simulateur iOS..."
xcodebuild test \
  -project LANScreen.xcodeproj \
  -scheme LANScreen \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  CODE_SIGNING_ALLOWED=NO

if [[ -z "$TEAM_ID" ]]; then
  echo "Aucun TEAM_ID fourni : compilation générique sans signature (.ipa non généré)."
  xcodebuild build \
    -project LANScreen.xcodeproj \
    -scheme LANScreen \
    -configuration Release \
    -destination "generic/platform=iOS" \
    CODE_SIGNING_ALLOWED=NO
  exit 0
fi

echo "[4/4] Archivage et export du fichier IPA signé (Team: $TEAM_ID)..."
xcodebuild archive \
  -project LANScreen.xcodeproj \
  -scheme LANScreen \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  -allowProvisioningUpdates

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$ROOT_DIR/ExportOptions.plist" \
  -exportPath "$IPA_OUTPUT_DIR" \
  -allowProvisioningUpdates

echo "Succès : IPA généré dans $IPA_OUTPUT_DIR"
ls -lh "$IPA_OUTPUT_DIR"
