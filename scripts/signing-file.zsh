# Finds App/Signing.local.xcconfig, which holds this Mac's Apple Developer team (ignored by git, see
# App/Signing.xcconfig). Sourced by scripts/build-app.sh and scripts/build-iphone.sh from the repository's root.
#
# A new git worktree does not have that file: find_signing_file copies the one of the main checkout (the folder
# that holds the repository's shared .git), or of SIGNING_CHECKOUT=<absolute folder> when it is set, and says so.
# It fails when there is none; $signing_checkout then holds the folder it looked in (empty: no git repository).

signing_file=App/Signing.local.xcconfig
signing_checkout=""

find_signing_file() {
  [[ -f $signing_file ]] && return 0
  signing_checkout=${SIGNING_CHECKOUT:-}
  if [[ -z $signing_checkout ]]; then
    local common
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    signing_checkout=${common:h}
  fi
  [[ -f $signing_checkout/$signing_file ]] || return 1
  cp "$signing_checkout/$signing_file" "$signing_file"
  echo "signing : copied $signing_file from $signing_checkout (ignored by git)"
}
