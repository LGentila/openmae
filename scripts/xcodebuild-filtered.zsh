# Runs xcodebuild with a short output and a full log. Sourced by scripts/build-app.sh and scripts/build-iphone.sh
# from the repository's root.
#
# xcodebuild_filtered <log> <sources folder> <xcodebuild arguments…> runs xcodebuild with those arguments, keeps its
# full build log (its standard output) in <log>, and shows only the errors, the warnings about <sources folder>
# (App/Sources, iPhone/Sources) and the result line; its standard error (on a failure, the result line and the commands
# that failed) still comes through as is. When xcodebuild fails, it says so with the log's path and fails with
# xcodebuild's status, so that the script stops (set -e) instead of going on to an app left in the build folder by an
# earlier build: on 2026-10-27, a build that did not compile ended with the path of the app built before, and exit
# status 0.
xcodebuild_filtered() {
  local log=$1 sources=$2
  shift 2
  mkdir -p "${log:h}"
  local -a statuses=()
  # With pipefail the pipeline fails when xcodebuild does; $pipestatus then holds each command's status, xcodebuild's
  # first. grep's own failure (no line to show) is not a failed build.
  xcodebuild "$@" | tee "$log" | grep -E "error:|warning: .*/$sources/|BUILD (SUCCEEDED|FAILED)" \
    || statuses=($pipestatus)
  local code=${statuses[1]:-0}
  if (( code != 0 )); then
    echo "BUILD FAILED: xcodebuild ended with status $code. Full log: $log" >&2
    return $code
  fi
}
