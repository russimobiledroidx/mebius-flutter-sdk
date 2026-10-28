#!/usr/bin/env bash
# Publishes packages/mebius_screen to pub.dev from a staging copy.
#
# Why a copy: the repo root is the `mebius` package, and its .pubignore lists
# packages/ so the nested package stays out of mebius's archive. pub applies
# that rule to the nested package too, so publishing in place uploads almost
# nothing. A copy outside the repo is a plain package directory.
#
# The copy is the COMMITTED package (git archive HEAD), minus
# pubspec_overrides.yaml, so it is exactly what the hosted `mebius`
# constraint in pubspec.yaml resolves against.
#
#   tool/publish_mebius_screen.sh --dry-run   # validate
#   tool/publish_mebius_screen.sh             # publish (mebius first!)
#
# A dry run resolves `mebius` from this repo, so it validates before the
# matching mebius is on pub.dev. A real publish does not: it fails to resolve
# until that mebius version is published, which is the order it must happen in.
set -euo pipefail

repo="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
stage="$tmp/mebius_screen"
mkdir "$stage"

git -C "$repo" archive HEAD:packages/mebius_screen | tar -x -C "$stage"
find "$stage" -name pubspec_overrides.yaml -delete

if [[ " $* " == *" --dry-run "* ]]; then
  printf 'dependency_overrides:\n  mebius:\n    path: %s\n' "$repo" \
    > "$stage/pubspec_overrides.yaml"
fi

cd "$stage"
flutter pub publish "$@"
