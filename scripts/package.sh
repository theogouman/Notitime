#!/usr/bin/env bash
# Produit le bundle .app non signé dans dist/. L'installation demande une
# autorisation manuelle dans les réglages de sécurité macOS (distribution v1).
#
# Le packaging repart toujours de zéro : c'est l'artefact qu'on distribue, il
# doit être reproductible et ne rien hériter d'un build de développement.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Nettoyage =="
rm -rf build dist
scripts/generate.sh

scripts/build.sh

PRODUCTS="build/DerivedData/Build/Products/Release"
[ -d "$PRODUCTS/Notitime.app" ] || { echo "Bundle introuvable dans $PRODUCTS" >&2; exit 1; }

mkdir -p dist
cp -R "$PRODUCTS/Notitime.app" dist/
echo "Bundle produit : dist/Notitime.app"
lipo -archs dist/Notitime.app/Contents/MacOS/Notitime
