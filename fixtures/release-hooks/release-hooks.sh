#!/usr/bin/env bash
#
# The smallest complete hooks script, and the one the README points at: a node
# package, no Rust anywhere, `package.json` as the version-bearing file. Backs
# `checks.mkReleaseCommand-runs-repo-hooks`, whose job is to prove the release
# builder never learned what a Cargo workspace is.
#
# `assert-unpublished` is a no-op because this fixture publishes nothing. It is
# still written out: all four subcommands are mandatory, and "nothing to check"
# has to be said rather than left to fall through the case.
set -euo pipefail

refuse() {
  printf 'refusing to release: %s\n' "$*" >&2
  return 1
}

assert_ready() {
  command -v jq >/dev/null 2>&1 \
    || refuse 'jq is missing, and jq is what writes the version into package.json'
}

assert_unpublished() {
  :
}

describe() {
  local version=${1-}
  printf '%-9s %s -> %s\n' package "$(jq -r .version package.json)" "${version#v}"
}

set_version() {
  local version=${1-} updated
  updated=$(jq --arg version "$version" '.version = $version' package.json) || return 1
  printf '%s\n' "$updated" >package.json
  printf 'package.json\n'
}

case ${1-} in
  assert-ready) assert_ready ;;
  assert-unpublished) assert_unpublished "${2-}" ;;
  describe) describe "${2-}" ;;
  set-version) set_version "${2-}" ;;
  *)
    printf 'usage: release-hooks {assert-ready|assert-unpublished|describe|set-version} ARGUMENT\n' >&2
    exit 2
    ;;
esac
