#!/usr/bin/env bash
#
# What makes a release legal, as one file every caller runs rather than each
# caller's own version of it. A second copy of the version pattern or the
# ancestor check would drift, and a drifted guard is worse than none because it
# is trusted.
#
# Three callers: `release` and the repository's own hooks, both of which get
# this on PATH from the wrapper, and a consuming repository's CI, which has to
# re-check a tag that was pushed by hand and reaches it through the
# `releaseGuards` package instead.
#
# Everything down to `assert_tag_unused` is a pure function over stdin and
# arguments -- no repository, no network -- which is what lets
# `release-guards.test.sh` cover it exhaustively. The two below need a
# repository and are exercised by running them.
#
# The `cargo-*` subcommands are the exception to language neutrality, and they
# earn it: Cargo puts the version somewhere a one-line `sed` cannot safely
# reach (`version` under `[workspace.package]`, not `version` under a
# dependency), so every Rust consumer would otherwise write the same awk. A
# `package.json` needs `jq '.version = $version'` and no help from here.
set -euo pipefail

readonly stable_pattern='^v[0-9]+\.[0-9]+\.[0-9]+$'
readonly releasable_pattern='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$'
readonly conventional_header_pattern='^[a-zA-Z][a-zA-Z0-9]*(\([^)]*\))?(!)?: .'
readonly breaking_footer_pattern='^BREAKING[ -]CHANGE[[:space:]]*:'

# The `::error::` form puts the reason on the job summary. A guard that refuses
# in CI is the one line anyone needs from that run, and stderr alone leaves it
# buried in a log nobody expands.
refuse() {
  if [[ ${GITHUB_ACTIONS-} == true ]]; then
    printf '::error::%s\n' "$*" >&2
  else
    printf 'refusing to release: %s\n' "$*" >&2
  fi
  return 1
}

assert_releasable() {
  local version=${1-}
  [[ $version =~ $releasable_pattern ]] || refuse \
    "$(printf '%q is not a release version -- expected vMAJOR.MINOR.PATCH (v1.2.3) or a prerelease of one (v1.2.3-rc1)' "$version")"
}

is_stable() {
  [[ ${1-} =~ $stable_pattern ]]
}

latest_stable() {
  local latest
  latest=$(grep -E "$stable_pattern" | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1) || true
  printf '%s\n' "${latest:-0.0.0}"
}

next() {
  local bump=${1-} base major minor patch
  base=$(latest_stable)
  IFS=. read -r major minor patch <<<"$base"
  case $bump in
    major) printf 'v%d.0.0\n' "$((major + 1))" ;;
    minor) printf 'v%d.%d.0\n' "$major" "$((minor + 1))" ;;
    patch) printf 'v%d.%d.%d\n' "$major" "$minor" "$((patch + 1))" ;;
    *) refuse "$(printf '%q is not a bump -- expected major, minor, or patch' "$bump")" ;;
  esac
}

# Every conventional type is worth at least a patch, not just `feat` and `fix`.
# A range of nothing but `docs:` is still a range with something to ship, and a
# range of nothing but `chore:` still moves whatever the repository publishes.
#
# A range with no conventional commit in it at all reads `none` rather than
# `patch`, which is a different answer from "the smallest bump": it lets the
# caller refuse instead of releasing a version nobody chose.
conventional_bump() {
  local message='' header type bump='none' unread_records=1
  while ((unread_records)); do
    IFS= read -r -d '' message || unread_records=0
    header=$(printf '%s\n' "$message" | grep -m1 -v '^[[:space:]]*$' || true)
    if [[ $header =~ $conventional_header_pattern ]]; then
      if [[ ${BASH_REMATCH[2]} == '!' ]] \
        || printf '%s\n' "$message" | grep -qE "$breaking_footer_pattern"; then
        printf 'major\n'
        return 0
      fi
      type=${header%%[(!:]*}
      if [[ ${type,,} == feat ]]; then
        bump='minor'
      elif [[ $bump == none ]]; then
        bump='patch'
      fi
    fi
    message=''
  done
  printf '%s\n' "$bump"
}

# Below 1.0 a breaking change is a minor bump, because a 0.x minor bump already
# *is* the breaking bump under both Cargo's and npm's compatibility rules: `0.3`
# and `0.4` are incompatible ranges, so `major` has nothing left to express that
# `minor` does not. Letting a `!` reach `v1.0.0` would spend the one version
# string that is a claim about stability on what is only a description of a
# change. A deliberately named `major` is the sole path to `v1.0.0`.
effective_bump() {
  local bump=${1-} base=${2-}
  case $bump in
    major | minor | patch) ;;
    *) refuse "$(printf '%q is not a bump -- expected major, minor, or patch' "$bump")" ;;
  esac
  [[ $base =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || refuse "$(printf '%q is not a released version -- expected MAJOR.MINOR.PATCH' "$base")"
  if [[ $bump == major && $base == 0.* ]]; then
    printf 'minor\n'
  else
    printf '%s\n' "$bump"
  fi
}

cargo_workspace_version() {
  awk '
    /^[[:space:]]*\[/ { in_workspace_package = ($0 ~ /^[[:space:]]*\[workspace\.package\][[:space:]]*$/) }
    in_workspace_package && !found && /^[[:space:]]*version[[:space:]]*=/ && match($0, /"[^"]*"/) {
      print substr($0, RSTART + 1, RLENGTH - 2)
      found = 1
    }
    END { if (!found) exit 1 }
  ' || refuse 'Cargo.toml has no version under [workspace.package] -- the release cannot read a crate version'
}

set_cargo_workspace_version() {
  local version=${1-}
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] \
    || refuse "$(printf '%q is not a crate version -- expected MAJOR.MINOR.PATCH, without the v' "$version")"
  awk -v version="$version" '
    /^[[:space:]]*\[/ { in_workspace_package = ($0 ~ /^[[:space:]]*\[workspace\.package\][[:space:]]*$/) }
    in_workspace_package && !replaced && /^[[:space:]]*version[[:space:]]*=/ {
      sub(/=.*/, "= \"" version "\"")
      replaced = 1
    }
    { print }
    END { if (!replaced) exit 1 }
  ' || refuse 'Cargo.toml has no version under [workspace.package] -- the release cannot set a crate version'
}

assert_tag_unused() {
  local version=${1-}
  git rev-parse -q --verify "refs/tags/$version" >/dev/null || return 0
  refuse "$version already exists, at $(git rev-list -n1 "$version") -- a released version is never re-pointed; release the next version instead"
}

assert_on_main() {
  local commit=${1-}
  # NOTE: fetched here, not assumed. A runner checked out at a tag has the
  # commits but no origin/main ref to compare against.
  git fetch --quiet --no-tags origin main
  git merge-base --is-ancestor "$commit" FETCH_HEAD && return 0
  refuse "$commit is not an ancestor of origin/main -- only what is merged to main is releasable; merge it first, then release the merge result"
}

case ${1-} in
  assert-releasable) assert_releasable "${2-}" ;;
  is-stable) is_stable "${2-}" ;;
  latest-stable) latest_stable ;;
  next) next "${2-}" ;;
  conventional-bump) conventional_bump ;;
  effective-bump) effective_bump "${2-}" "${3-}" ;;
  cargo-workspace-version) cargo_workspace_version ;;
  set-cargo-workspace-version) set_cargo_workspace_version "${2-}" ;;
  assert-tag-unused) assert_tag_unused "${2-}" ;;
  assert-on-main) assert_on_main "${2-}" ;;
  *)
    printf 'usage: release-guards {assert-releasable|is-stable|latest-stable|next|conventional-bump|effective-bump|cargo-workspace-version|set-cargo-workspace-version|assert-tag-unused|assert-on-main} ARGUMENT\n' >&2
    exit 2
    ;;
esac
