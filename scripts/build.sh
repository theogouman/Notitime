#!/usr/bin/env bash
# Build universel de la cible applicative. Ne doit produire aucun warning Swift.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d Notitime.xcodeproj ] || scripts/generate.sh

xcodebuild build \
  -project Notitime.xcodeproj \
  -scheme Notitime \
  -configuration Release \
  -destination 'platform=macOS' \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO
