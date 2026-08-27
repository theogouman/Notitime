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

# Signature ad-hoc. Elle ne coûte ni compte développeur ni certificat, et donne
# au bundle une identité de code — ce qui manque à un bundle non signé pour que
# le centre de notifications accepte de lui accorder une autorisation (FR-032).
# Elle ne remplace pas une signature Developer ID : Gatekeeper demandera
# toujours une autorisation manuelle à la première ouverture.
echo "== Signature ad-hoc =="
codesign --force --deep --sign - dist/Notitime.app
codesign --verify --verbose=1 dist/Notitime.app 2>&1 | sed 's/^/  /'

# L'icône qu'affiche le centre de notifications est celle du bundle enregistré
# auprès de LaunchServices pour `com.notitime.app`. Plusieurs copies coexistent
# — DerivedData, build/, dist/ — et le système peut retenir celle d'un build
# antérieur, dépourvu d'icône. On enregistre donc explicitement celle qu'on
# distribue. Sans effet sur la signature ni sur le contenu du bundle.
echo "== Enregistrement auprès de LaunchServices =="
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f dist/Notitime.app && echo "  icône et identité à jour pour com.notitime.app"
else
  echo "  lsregister introuvable — icône de notification possiblement périmée" >&2
fi

echo "Bundle produit : dist/Notitime.app"
lipo -archs dist/Notitime.app/Contents/MacOS/Notitime
