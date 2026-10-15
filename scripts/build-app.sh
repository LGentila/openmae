#!/bin/zsh
# Builds the macOS app.
#   1. generates the Xcode project from App/project.yml (xcodegen: brew install xcodegen)
#   2. compiles it (Release by default; CONFIGURATION=Debug zsh scripts/build-app.sh for a debug build)
# The app ends up in .build/app/Build/Products/<configuration>/<product name>.app
set -euo pipefail
cd "$(dirname "$0")/.."
project=$(awk '/^name:/ {print $2; exit}' App/project.yml)       # Xcode project and scheme
product=$(awk '/PRODUCT_NAME:/ {print $2; exit}' App/project.yml)  # file name of the app (no accent)
configuration=${CONFIGURATION:-Release}

xcodegen generate --spec App/project.yml --quiet
xcodebuild -project "App/$project.xcodeproj" -scheme "$project" -configuration "$configuration" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/app \
  -skipMacroValidation -skipPackagePluginValidation build \
  | grep -E "error:|warning: .*/App/Sources/|BUILD (SUCCEEDED|FAILED)" || true

app=".build/app/Build/Products/$configuration/$product.app"
[[ -d "$app" ]] && echo "app : $app"
