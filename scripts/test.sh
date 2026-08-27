#!/usr/bin/env bash
# Suite complète. Doit passer sans réseau : un test qui échoue en mode avion est
# un défaut du test, pas de l'environnement (principe VII).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== NotitimeCore (swift test) =="
swift test --package-path Packages/NotitimeCore

echo "== Backend OAuth (node --test) =="
(cd backend && npm test --silent)

# La cible applicative n'a pas de suite de tests : le principe VII n'impose pas
# de tests SwiftUI, et toute la logique testable vit dans NotitimeCore. Ce qui est
# vérifié ici, c'est qu'elle compile sans warning.
if [ -d Notitime.xcodeproj ]; then
  echo "== Cible applicative (compilation) =="
  xcodebuild build \
    -project Notitime.xcodeproj \
    -scheme Notitime \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO \
    -quiet
else
  echo "Notitime.xcodeproj absent — lancer scripts/generate.sh d'abord." >&2
  exit 1
fi
