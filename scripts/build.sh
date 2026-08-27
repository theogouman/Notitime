#!/usr/bin/env bash
# Build universel de la cible applicative. Ne doit produire aucun warning Swift.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d Notitime.xcodeproj ] || scripts/generate.sh

# DerivedData local au dépôt, et non le cache partagé de ~/Library.
#
# Le cache partagé est indexé sur un hachage du chemin du projet : déplacer le
# dépôt en crée un nouveau et laisse l'ancien traîner. Surtout, il mélange les
# configurations — un NotitimeCore compilé pour la seule architecture active en
# Debug y côtoie une demande Release universelle, et la tranche x86_64 manquante
# fait échouer SwiftDriver. Un cache par dépôt rend `rm -rf build/` suffisant.
xcodebuild build \
  -project Notitime.xcodeproj \
  -scheme Notitime \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO
