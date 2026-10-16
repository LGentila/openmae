#!/bin/zsh
# Builds the iPhone app and installs it on the iPhone connected to this Mac (cable or Wi-Fi, unlocked).
#   1. generates the Xcode project from iPhone/project.yml (xcodegen: brew install xcodegen)
#   2. compiles it for the iPhone (Debug by default; CONFIGURATION=Release for a release build), signed
#      automatically with the team of App/Signing.local.xcconfig
#   3. installs it and opens it with devicectl
# SIMULATOR=1 builds for the simulator instead (no signing team needed) and prints the app's path.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=${CONFIGURATION:-Debug}

xcodegen generate --spec iPhone/project.yml --quiet

if [[ -n "${SIMULATOR:-}" ]]; then
  xcodebuild -project iPhone/OpenMaeiPhone.xcodeproj -scheme OpenMae -configuration "$configuration" \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-sim \
    -skipMacroValidation -skipPackagePluginValidation build \
    | grep -E "error:|warning: .*/iPhone/Sources/|BUILD (SUCCEEDED|FAILED)" || true
  echo "app : .build/iphone-sim/Build/Products/$configuration-iphonesimulator/OpenMae.app"
  exit 0
fi

# The first iPhone that devicectl can reach (its state "available" or "connected", not "unavailable").
device=${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && (/ available / || / connected /) {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')}
if [[ -z "$device" ]]; then
  echo "No iPhone available: connect it (or put it on the same Wi-Fi), unlock it, then try again."
  exit 1
fi

xcodebuild -project iPhone/OpenMaeiPhone.xcodeproj -scheme OpenMae -configuration "$configuration" \
  -destination "id=$device" -derivedDataPath .build/iphone -allowProvisioningUpdates \
  -skipMacroValidation -skipPackagePluginValidation build \
  | grep -E "error:|warning: .*/iPhone/Sources/|BUILD (SUCCEEDED|FAILED)" || true

app=".build/iphone/Build/Products/$configuration-iphoneos/OpenMae.app"
[[ -d "$app" ]] || exit 1
xcrun devicectl device install app --device "$device" "$app"
xcrun devicectl device process launch --device "$device" com.openmae.ios
