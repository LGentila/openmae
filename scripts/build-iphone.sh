#!/bin/zsh
# Builds the iPhone and iPad app and installs it on the iPhone or iPad connected to this Mac (cable or Wi-Fi, unlocked).
#   1. generates the Xcode project from iPhone/project.yml (xcodegen: brew install xcodegen)
#   2. compiles it for the device (Debug by default; CONFIGURATION=Release for a release build), signed
#      automatically with the team of App/Signing.local.xcconfig
#   3. installs it and opens it with devicectl
# DEVICE=<identifier> picks the device when several are connected (xcrun devicectl list devices); DEVICE=iPad or
# DEVICE=iPhone picks the first one of that kind.
# SIMULATOR=1 builds for the simulator instead (no signing team needed; the same app runs on the iPhone and iPad
# simulators) and prints the app's path. SIMULATOR="iPad mini (6th generation)" (or any simulator's name, or its
# identifier) also starts that simulator, installs the app on it and opens it.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=${CONFIGURATION:-Debug}

xcodegen generate --spec iPhone/project.yml --quiet

if [[ -n "${SIMULATOR:-}" ]]; then
  xcodebuild -project iPhone/OpenMaeiPhone.xcodeproj -scheme OpenMae -configuration "$configuration" \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/iphone-sim \
    -skipMacroValidation -skipPackagePluginValidation build \
    | grep -E "error:|warning: .*/iPhone/Sources/|BUILD (SUCCEEDED|FAILED)" || true
  app=".build/iphone-sim/Build/Products/$configuration-iphonesimulator/OpenMae.app"
  echo "app : $app"
  [[ "$SIMULATOR" == 1 ]] && exit 0
  [[ -d "$app" ]] || exit 1
  # The simulator by name (with the newest system, listed last) or by identifier.
  simulator=$(xcrun simctl list devices available | awk -v name="$SIMULATOR" '
    index($0, name " (") || index($0, "(" name ")") {
      if (match($0, /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/)) found = substr($0, RSTART, RLENGTH)
    }
    END { if (found) print found }')
  if [[ -z "$simulator" ]]; then
    echo "No simulator called \"$SIMULATOR\": see xcrun simctl list devices available."
    exit 1
  fi
  xcrun simctl boot "$simulator" 2>/dev/null || true  # already booted: fine
  open -a Simulator --args -CurrentDeviceUDID "$simulator" 2>/dev/null || true  # its window, when Xcode has it
  xcrun simctl install "$simulator" "$app"
  xcrun simctl launch "$simulator" com.openmae.ios
  exit 0
fi

# The first iPhone or iPad that devicectl can reach (its state "available" or "connected", not "unavailable"); with
# DEVICE=iPad or DEVICE=iPhone, the first one of that kind.
kind=""
[[ "${DEVICE:-}" == iPad || "${DEVICE:-}" == iPhone ]] && kind=$DEVICE && DEVICE=""
device=${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk -v kind="$kind" '/physical/ && (/ available / || / connected /) && (kind == "" || index($0, kind)) {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/ || $i ~ /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/) {print $i; exit}}')}
if [[ -z "$device" ]]; then
  echo "No ${kind:-iPhone or iPad} available: connect it (or put it on the same Wi-Fi), unlock it, then try again."
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
