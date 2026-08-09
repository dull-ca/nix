#!/usr/bin/env bash
#
# The order below is the whole point: every guard runs before anything is
# created, so a rejected release leaves no tag, no artifact, and nothing to
# undo. That holds until the release commit reaches main -- the one step after
# which a refusal leaves something behind, and by then the only thing left to do
# is the tag.
#
# The tag is pushed from here rather than from a workflow because a push
# carrying GITHUB_TOKEN starts no workflow run, and a release that publishes
# from CI needs its tag push to start one.
#
# Nothing here knows what the calling repository publishes. Everything
# repo-shaped arrives in the RELEASE_* environment, which `mkReleaseCommand`
# bakes into a wrapper -- so this file is never run bare, and an empty variable
# means "this repository does not do that", not "not configured yet".
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# NOTE: `main` and `CHANGELOG.md` are constants rather than options because
# there is exactly one sane value for each. A knob whose every caller passes the
# same argument is a knob that only adds a way to be wrong.
#
# `release-guards` is found on PATH, not by path: the wrapper puts it there, and
# putting it there also lets the hooks call it (`describe` asks `is-stable`, a
# Rust `set-version` asks `set-cargo-workspace-version`).
#
# `?` marks the two the wrapper always sets -- `mkReleaseCommand` defaults the
# timeout and resolves the config, so an empty one is a broken wrapper rather
# than a repository that opted out, and failing on the expansion says so here
# instead of at the git-cliff call. The other three take `-` because empty is an
# answer: no hooks, no cache to warm, no workflow to watch.
readonly guards=release-guards
readonly hooks=${RELEASE_HOOKS-}
readonly cliff_config=${RELEASE_CLIFF_CONFIG?}
readonly warm_command=${RELEASE_WARM_COMMAND-}
readonly workflow=${RELEASE_WORKFLOW-}
readonly watch_timeout_seconds=${RELEASE_WATCH_TIMEOUT_SECONDS?}
readonly changelog=CHANGELOG.md
readonly requested=${1-}

refuse() {
  printf 'refusing to release: %s\n' "$*" >&2
  exit 1
}

# A repository with no hooks at all is the one case where a missing hook is
# silence rather than a failure: nothing was promised, so nothing is skipped.
# The moment a hooks script exists it must answer all four subcommands --
# `assert-ready`, `describe`, `assert-unpublished`, `set-version` -- because
# dispatch here cannot tell "this repository has nothing to check" from "the
# case fell through". A publish guard that quietly does not run is worse than
# one that was never written, so a repository with nothing to do writes the
# no-op explicitly and the absence of a subcommand stays an error.
hook() {
  [[ -n $hooks ]] || return 0
  "$hooks" "$@"
}

command -v git-cliff >/dev/null 2>&1 \
  || refuse 'git-cliff is missing, and git-cliff is what writes the changelog -- nix profile install nixpkgs#git-cliff'
if [[ -n $workflow ]]; then
  command -v gh >/dev/null 2>&1 \
    || refuse "gh is missing, and gh is what waits for the $workflow run -- nix profile install nixpkgs#gh"
  gh auth status >/dev/null 2>&1 \
    || refuse "gh is not authenticated, and gh is what waits for the $workflow run -- run: gh auth login"
fi
[[ -f $cliff_config ]] || refuse "$cliff_config is missing, and it is the whole changelog format"

branch=$(git symbolic-ref --quiet --short HEAD) || refuse 'HEAD is detached -- release from main'
[[ $branch == main ]] || refuse "on branch $branch -- release from main"
[[ -z $(git status --porcelain) ]] || refuse 'the working tree is dirty -- commit or stash first'

hook assert-ready

git fetch --quiet origin main
git merge-base --is-ancestor origin/main HEAD \
  || refuse 'main is behind origin/main -- git pull first'

tags=$(git tag --list 'v*')
base=$(printf '%s\n' "$tags" | "$guards" latest-stable)

if git rev-parse -q --verify "refs/tags/v$base" >/dev/null; then
  released_range="v$base..HEAD"
  since="since v$base"
else
  released_range=HEAD
  since='in the whole history'
fi

unreleased_count=$(git rev-list --count "$released_range")
((unreleased_count > 0)) || refuse "nothing is unreleased $since -- there is no release to make"

if ((unreleased_count == 1)); then
  merges="1 merge $since"
else
  merges="$unreleased_count merges $since"
fi

# The version follows from the commits unless a version is named. `main` is
# squash-merged, so every commit in the range is one pull request and its
# subject is the only conventional signal that pull request left behind.
#
# A range where not one subject parses gets no version invented for it. The
# alternative is guessing a patch, and a guess here is silent: the same subjects
# that carried no bump are the ones CHANGELOG.md is about to be written from, so
# a range that says nothing about itself is one to reword. Naming the version on
# the command line is the way past this when the rewording is not worth it.
case $requested in
  '')
    conventional=$(git log --format='%B%x00' "$released_range" | "$guards" conventional-bump)
    [[ $conventional != none ]] || refuse \
      "no conventional commit is among the $merges, so no version follows from them -- reword the squash subjects, or name the version: release v${base%.*}.$((${base##*.} + 1))"
    bump=$("$guards" effective-bump "$conventional" "$base")
    version=$(printf '%s\n' "$tags" | "$guards" next "$bump")
    if [[ $bump == "$conventional" ]]; then
      derivation="$bump, read from $merges"
    else
      derivation="$bump, read from $merges -- $conventional softened, because 0.x has no compatibility to break"
    fi
    ;;
  major | minor | patch)
    version=$(printf '%s\n' "$tags" | "$guards" next "$requested")
    derivation="$requested, named on the command line"
    ;;
  *)
    version=$requested
    derivation='named on the command line'
    ;;
esac

commit=$(git rev-parse HEAD)
"$guards" assert-releasable "$version"
"$guards" assert-tag-unused "$version"
"$guards" assert-on-main "$commit"
hook assert-unpublished "$version"

section=$(git-cliff --config "$cliff_config" --tag "$version" --unreleased --strip header)
[[ -n ${section//[[:space:]]/} ]] || refuse \
  "git-cliff found nothing to record for $version -- every unreleased commit is one $cliff_config skips"

summary=$(hook describe "$version")

printf '\n'
printf '  %-9s %s  %s\n' commit "$(git rev-parse --short HEAD)" "$(git log -1 --format=%s)"
printf '  %-9s %s  (%s)\n' version "$version" "$derivation"
[[ -z $summary ]] || printf '%s\n' "$summary" | sed 's/^./  &/'
printf '\n'
printf '  A release commit carrying %s and every version-bearing file lands on\n' "$changelog"
printf '  main first, and %s tags that commit -- one past the one above.\n' "$version"
printf '\n'
# Printed before the question, not after it: this list is the last chance to
# catch a bump read from a subject that undersold its pull request. Nothing
# downstream can see past the subject either — the same words become the
# changelog line.
printf '  Every merge the version was read from -- a squash subject is written by hand\n'
printf '  at merge time, and it is all this can see of the pull request it stands for:\n'
printf '\n'
while read -r merge; do
  asked=$(git log -1 --format='%B%x00' "$merge" | "$guards" conventional-bump)
  if [[ $asked == none ]]; then asked='-'; fi
  printf '    %s  %-5s  %s\n' \
    "$(git rev-parse --short "$merge")" "$asked" "$(git log -1 --format=%s "$merge")"
done < <(git rev-list --reverse "$released_range")
printf '\n'
printf '  Every line %s gains:\n' "$changelog"
printf '%s\n' "$section" | sed 's/^  *$//;s/^./    &/'
printf '\n'

read -rp 'Release this? Type Y to continue: ' confirmation
[[ $confirmation == Y ]] || refuse 'not confirmed'

# NOTE: the second line is for the first release only. `git reset --hard` leaves
# a file that is untracked at $commit exactly where it is, so a repository whose
# first release is also its first CHANGELOG.md would be unwound into a dirty
# tree -- and a dirty tree is what the next release refuses on.
unwind_to_reviewed_commit() {
  git reset --hard --quiet "$commit"
  git ls-files --error-unmatch "$changelog" >/dev/null 2>&1 || rm -f "$changelog"
}

# `set-version` prints the paths it wrote, one per line, and those paths are
# what gets staged. That inversion is what keeps the version-bearing file out of
# this file: a Rust workspace names `Cargo.toml` and `Cargo.lock`, a node package
# names `package.json`, a repository that publishes a container and versions
# nothing on disk names nothing at all and still gets a release commit. Only
# `CHANGELOG.md` is named here, because only `CHANGELOG.md` is written here.
#
# Staging is deliberately not the hook's job either. The hook that writes a file
# is the only thing that knows it wrote one; the driver is the only thing that
# knows whether the commit is still going to happen.
prepare_release_commit() {
  local staged_by_hook path
  local -a versioned=()
  git-cliff --config "$cliff_config" --tag "$version" --output "$changelog" || return 1
  staged_by_hook=$(hook set-version "${version#v}") || return 1
  if [[ -n $staged_by_hook ]]; then
    while IFS= read -r path; do versioned+=("$path"); done <<<"$staged_by_hook"
  fi
  git add -- "$changelog" "${versioned[@]}" || return 1
  git commit --quiet -m "chore(release): $version"
}

if ! prepare_release_commit; then
  unwind_to_reviewed_commit
  refuse "the release commit could not be prepared -- $commit is restored, nothing was pushed"
fi
release_commit=$(git rev-parse HEAD)

# Runs after the release commit rather than before it, because the tag is on
# that commit -- warming the reviewed tree would warm a tree the runner never
# sees. The bill is a rebuild of everything the version-bearing files feed, on
# every release; the return is that a red gate costs no tag.
#
# NOTE: `$warm_command` is unquoted on purpose, so a caller can pass a command
# with arguments. It is a nix-supplied string, not user input.
if [[ -n $warm_command ]]; then
  printf '\nwarming the cache, so the release run is a hit...\n'
  if ! $warm_command; then
    unwind_to_reviewed_commit
    refuse "the gate failed on the release commit -- $commit is restored, nothing was pushed"
  fi
fi

if ! git push --quiet origin "$release_commit:refs/heads/main"; then
  unwind_to_reviewed_commit
  refuse "pushing the release commit to main failed -- $commit is restored, no tag exists"
fi

# Asked again, of the state the push just produced. The earlier answers were
# about the reviewed commit and about a moment before anyone else's merge could
# land; these are about the commit the tag will name and a tag that a concurrent
# release may have taken since. The tag is still the last thing created, so a
# refusal here costs a release commit sitting on main untagged -- the version
# stays unspent and the next release carries that commit in its own range.
"$guards" assert-tag-unused "$version"
"$guards" assert-on-main "$release_commit"

git tag -a "$version" -m "Release $version" "$release_commit"
git push origin "refs/tags/$version"

announce_release() {
  printf '\nreleased %s\n' "$version"
  [[ -z $summary ]] || printf '%s\n' "$summary" | sed 's/^./  &/'
}

if [[ -z $workflow ]]; then
  announce_release
  exit 0
fi

printf '\nwaiting for the release run...\n'
run_id=''
deadline=$((SECONDS + watch_timeout_seconds))
while ((SECONDS < deadline)); do
  # NOTE: polled for this release's run rather than taken as the newest, which
  # would land on the wrong one — the push and the run appearing are seconds
  # apart. Matched on the commit as well as the tag: the workflow only ever runs
  # on a tag push, so the sha identifies the run, and `head_branch` holding a tag
  # name is undocumented behaviour to lean on alone.
  run_id=$(gh run list --workflow "$workflow" --limit 20 \
    --json databaseId,headBranch,headSha \
    --jq "map(select(.headBranch == \"$version\" or .headSha == \"$release_commit\")) | first | .databaseId // empty") || true
  if [[ -n $run_id ]]; then break; fi
  sleep 5
done

if [[ -z $run_id ]]; then
  printf 'no release run appeared for %s within %ds. The tag is pushed -- look for the run with:\n  gh run list --workflow %s\n' \
    "$version" "$watch_timeout_seconds" "$workflow" >&2
  exit 1
fi

run_url=$(gh run view "$run_id" --json url --jq .url)
printf '  %s\n\n' "$run_url"

remaining=$((deadline - SECONDS))
# NOTE: never 0 -- `timeout 0` is `timeout never`, and never is the one outcome
# this wait must not have.
((remaining > 0)) || remaining=60

watch_status=0
timeout "$remaining" gh run watch "$run_id" --exit-status --interval 10 || watch_status=$?

if ((watch_status == 0)); then
  announce_release
  printf '  %-9s %s\n' run "$run_url"
  exit 0
fi

if ((watch_status == 124)); then
  printf '\nstill running after %ds -- not a failure, just longer than the wait:\n  %s\n' \
    "$watch_timeout_seconds" "$run_url" >&2
  exit 1
fi

{
  printf '\nTHE RELEASE RUN FAILED. Nothing was published.\n'
  printf '  run  %s\n' "$run_url"
  printf '\n%s is now taken, and the guards will refuse it again. Fix main and release the\n' "$version"
  printf 'next version -- or retire this tag yourself with:\n  git push origin --delete %s\n' "$version"
} >&2
exit 1
