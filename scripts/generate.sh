#!/usr/bin/env bash
# Régénère Notitime.xcodeproj depuis project.yml. À relancer après toute
# modification de project.yml. Le .xcodeproj n'est jamais édité à la main.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen absent : brew install xcodegen" >&2; exit 1; }
xcodegen generate --spec project.yml
