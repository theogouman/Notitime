#!/usr/bin/env bash
# Produit le bundle .app non signé dans dist/. L'installation demande une
# autorisation manuelle dans les réglages de sécurité macOS (distribution v1).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh

DERIVED=$(xcodebuild -project Notitime.xcodeproj -scheme Notitime -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')

rm -rf dist && mkdir -p dist
cp -R "$DERIVED/Notitime.app" dist/
echo "Bundle produit : dist/Notitime.app"
lipo -archs dist/Notitime.app/Contents/MacOS/Notitime 2>/dev/null || true
