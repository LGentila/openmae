#!/bin/zsh
# Builds the macOS app.
#   1. finds the signing file App/Signing.local.xcconfig (below)
#   2. generates the Xcode project from App/project.yml (xcodegen: brew install xcodegen)
#   3. compiles it (Release by default; CONFIGURATION=Debug zsh scripts/build-app.sh for a debug build), showing
#      only the errors, the warnings about App/Sources and the result (full build log: .build/app/xcodebuild.log);
#      when the build fails, it stops there with an error, without printing the path of the older app left in the folder
#   4. prints the app's path and the identity it is signed with
# The app ends up in .build/app/Build/Products/<configuration>/<product name>.app
#
# Signing: the app is signed with the Apple Developer team of App/Signing.local.xcconfig (ignored by git). A new git
# worktree does not have it: the script copies the main checkout's one (SIGNING_CHECKOUT=<absolute folder> looks in
# another checkout instead). When there is none, it stops rather than sign the app "to run locally" (ad hoc): an ad
# hoc copy has the same bundle id as the normal app, so macOS asks again for the microphone, calendars and reminders,
# and once they are allowed, the permissions follow that copy and leave the normally signed app. ADHOC=1 builds ad hoc
# on purpose, even when the signing file is there.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing-file.zsh
source scripts/xcodebuild-filtered.zsh
project=$(awk '/^name:/ {print $2; exit}' App/project.yml)       # Xcode project and scheme
product=$(awk '/PRODUCT_NAME:/ {print $2; exit}' App/project.yml)  # file name of the app (no accent)
configuration=${CONFIGURATION:-Release}
adhoc=${ADHOC:-0}
[[ $adhoc == 0 ]] && adhoc=""

signing_settings=()
if [[ -n $adhoc ]]; then
  signing_settings=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)  # over Signing.local.xcconfig, if any
  echo "signing : ad hoc (ADHOC=1); do not open this app unless you mean it: macOS will ask again for the"
  echo "          microphone, calendars and reminders, and the permissions allowed leave the normally signed app"
elif ! find_signing_file; then
  cat >&2 <<EOF
Not built: no signing file. $signing_file is missing here, and in ${signing_checkout:-the main checkout (no git repository found)} too.
Without it the app would be signed "to run locally" (ad hoc), with the same bundle id as the normal app: macOS would
ask again for the microphone, calendars and reminders, and once they are allowed, the permissions would move to this
copy and leave the normally signed app, which would then ask again (and so would every new ad hoc build).
  - To sign with your Apple Developer team: copy App/Signing.local.xcconfig.example to $signing_file and
    put your team ID in it, or point SIGNING_CHECKOUT at the folder of a checkout that has one.
  - To build ad hoc anyway: ADHOC=1 zsh scripts/build-app.sh
EOF
  exit 1
fi

xcodegen generate --spec App/project.yml --quiet
# Stops here when the build fails: the app in the folder would be an older one.
xcodebuild_filtered .build/app/xcodebuild.log App/Sources \
  -project "App/$project.xcodeproj" -scheme "$project" -configuration "$configuration" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/app \
  -skipMacroValidation -skipPackagePluginValidation build "${signing_settings[@]}"

app=".build/app/Build/Products/$configuration/$product.app"
[[ -d "$app" ]] || { echo "No app at $app, although the build succeeded." >&2; exit 1 }
echo "app : $app"

# The identity the app is signed with, so that a wrong signature shows at once.
signature=$(codesign -dvv "$app" 2>&1) || true  # -vv for the Authority lines
authority=$(print -r -- "$signature" | awk '/^Authority=/ {print substr($0, 11); exit}')
team=$(print -r -- "$signature" | awk -F= '/^TeamIdentifier=/ {print $2; exit}')
if [[ -n $authority && $signature != *Signature=adhoc* ]]; then
  echo "signing : $authority, team ${team:-not set}"
elif [[ -n $adhoc ]]; then
  echo "signing : ad hoc (ADHOC=1)"
else
  echo "signing : not signed with a team (ad hoc), although ADHOC=1 was not asked: check $signing_file" >&2
  echo "          and do not open this app: its permission prompts would move the permissions away from the normal app" >&2
  exit 1
fi
