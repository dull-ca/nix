# dull-ca/nix

Shared nix packages for dull-ca. Consume them as a flake input:

```nix
inputs.dull-nix.url = "github:dull-ca/nix";
```

## `nginx-static-no-tls`

A statically linked nginx (~1.69 MB closure, **zero store references**) for
serving static files from a container.

**It cannot serve HTTPS.** `ngx_http_ssl_module` is not compiled in, so
pointing it at an `ssl` listener fails at startup:

```
nginx: [emerg] the "ssl" parameter requires ngx_http_ssl_module
```

Run it behind a TLS-terminating reverse proxy. **Never expose it directly to
the internet.** The `-no-tls` in the name is that constraint, not a
description — misuse shows up immediately as plaintext, not as something
silently insecure.

### What's compiled in

Not "no modules" — nginx's *default* module set, minus the upstream family
(proxying to another service) and minus everything opt-in.

**Absent:** TLS/SSL, HTTP/2, HTTP/3, `proxy`, `fastcgi`, `uwsgi`, `scgi`,
`memcached`, `xslt`, `dav`, `flv`, `mp4`, `sub`, `auth_request`,
`secure_link`, `stub_status`, `stream`, `mail`, `perl`, `geoip`.

**Present:** `gzip_static`, `threads`, `realip` (added explicitly), plus the
modules nginx ships on by default: `autoindex`, `ssi`, `auth_basic`,
`rewrite`, `limit_req`, `limit_conn`, `access`, `charset`, `gzip`, `map`,
`geo`, `referer`.

`autoindex` and `ssi` both default to *off*. Turning either on should be a
decision you make on purpose, not something that's already there.

### Why this is its own build, not `nginx.override`

`nginx.override` is nixpkgs' supported way to reconfigure a package, and it
was tried first. It can't produce this build: nixpkgs' `generic.nix`
hardcodes an unconditional module list (`ssl`, `v3`, `xslt`, `dav`, `flv`,
`mp4`) with no argument gating it, and the `configureFlags` it exposes only
*appends* to nginx's `./configure` call. nginx's `./configure` has no
`--without-` flag for a module that was never `--with-`'d, so there is no
way to append your way out of a module `generic.nix` already turned on.

The derivation here calls nginx's `./configure` directly instead, so the
module list is ours to set. It still inherits `src` and `version` from
`pkgs.nginx` — this repo owns the build configuration, not the source or the
version.

### How security updates reach this package

Because `src` and `version` come from `pkgs.nginx`, nixpkgs decides which
nginx gets built here — an nginx CVE fix arrives as a nixpkgs bump like any
other. `.github/workflows/update.yml` runs `nix flake update` weekly and
opens a CI-tested pull request. **Merging those PRs is what keeps this
package patched** — nothing else pulls the fix in.

### Deploying it

`realip` is compiled in, but nginx still needs `set_real_ip_from` configured
with your reverse proxy's actual address range before it will trust the
`X-Forwarded-For` it's given — that range is the deploying project's call to
make, not this package's. Never set it to `0.0.0.0/0`: that lets any client
supply its own address and have it recorded as the truth in your logs.

## `buildBunPackage`

A `buildNpmPackage`-equivalent for bun: fetches `bun.lock`-pinned deps as a
fixed-output derivation, no build-time network access, then runs the build script.

```nix
{
  inputs.dull-nix.url = "github:dull-ca/nix";

  outputs = { self, nixpkgs, dull-nix, ... }: {
    packages.x86_64-linux.site =
      let
        pkgs = import nixpkgs {
          system = "x86_64-linux";
          overlays = [ dull-nix.overlays.default ];
        };
      in
      pkgs.buildBunPackage {
        pname = "site";
        src = ./.;
        bunDepsHash = "sha256-...";
      };
  };
}
```

`buildScript` (default `"build"`) and `installDir` (default `"dist"`) cover
the common case; everything else forwards to `mkDerivation`, and a caller's
own `nativeBuildInputs`/`buildInputs`/`passthru` merge in rather than replace.

nixpkgs-unstable has `fetchNpmDeps`/`pnpm.fetchDeps` but no bun equivalent —
`fetchBunDeps`/`buildBunPackage` fill that gap with the same fixed-output
approach. Like `npmDepsHash`, `bunDepsHash` needs bumping by hand on every
`bun.lock` change: set it to `pkgs.lib.fakeHash`, build, and take the real
value from the `got:` line of the mismatch nix reports.

It also runs `bun install --ignore-scripts`, so a dependency whose
postinstall does real work fails at build time instead — hit with
`lightningcss-cli` (`command not found` for `.bin/lightningcss` until
`postinstall.js` replaces it; fixed by depending on `lightningcss`, the
library, which needs none).

### Two settings that look removable but aren't

`autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ]` — bun installs
a `-musl` build of every native dependency alongside the `-gnu` one this
platform actually loads. The musl libc dependency is never really missing,
just never loaded. Delete the exclusion and `autoPatchelf` treats it as fatal:

```
auto-patchelf could not satisfy dependency libc.musl-x86_64.so.1
```

`patchShebangs node_modules` scans the whole tree, not just `.bin`. This
repo's fixture doesn't prove the wider scope necessary — `.bin` entries are
symlinks that `patchShebangs` follows to the same target either way. It is
necessary on the real dull.yyc.dev site build: Astro reaches
`node_modules/astro/astro.js` by a relative path, never through `.bin`, so the
narrow scan leaves its shebang unpatched and the build dies with a bad
interpreter.

`checks.buildBunPackage-builds-fixture` runs a real `bun install` against the
npm registry — the one non-hermetic check here, kept so a regression in
`buildBunPackage` doesn't surface only as a downstream repo's red CI.

## `fetchGleamDeps` and `buildGleamPackage`

The gleam pair to the bun one above: dependencies fetched from `manifest.toml`,
no build-time network, then `gleam` compiles.

```nix
pkgs.buildGleamPackage {
  pname = "server";
  src = ./server;
}
```

`target` (default `"erlang"`) picks the output. `"erlang"` exports an
`erlang-shipment` — the directory of `*/ebin` trees you run with `erl -pa`.
`"javascript"` gives the compiled JS tree for a bundler to take from. `erlang`
(default `beam27Packages.erlang`) picks the OTP the build runs on. Everything
else forwards to `mkDerivation`, and a caller's `nativeBuildInputs`/`passthru`
merge in rather than replace.

Because the arguments forward, replacing both phases is how you reuse the
resolved dependency tree for something other than a build:

```nix
pkgs.buildGleamPackage {
  pname = "server-test";
  src = ./server;
  buildPhase = "gleam test";
  installPhase = "touch $out";
}
```

### No hash to maintain, unlike `bunDepsHash`

`fetchGleamDeps` takes no hash argument, and the asymmetry with `fetchBunDeps`
right above it is deliberate rather than an oversight.

Gleam's `manifest.toml` records an `outer_checksum` for every hex package, and
that checksum *is* the SHA-256 of the tarball hex serves. Every hash the fetch
needs is therefore already in a file gleam maintains, so this is an ordinary
`fetchurl` per package rather than a fixed-output derivation over the whole
tree. Adding a dependency updates `manifest.toml` and nothing else has to
change. `fetchBunDeps` needs `bunDepsHash` because bun's lockfile records no
such digest — not because this one is cutting a corner.

`rebar3` and `gnumake` are always present: many hex packages are written in
erlang, gleam shells out to rebar3 to build those, and a builder missing it
fails only in whichever consumer first depends on one. The fixture carries
`thoas` for exactly that reason, and the check asserts its compiled beam
reached the shipment.

### What it will not do

A `source = "git"` dependency is **refused at evaluation time**. The manifest
carries no checksum for one, so nothing could verify the fetch; refusing is
better than a sandbox failing later with an unexplained network error. Depend
on a hex release or vendor the package as a path dependency.

A `source = "local"` path dependency is skipped, which is correct — gleam
resolves those from the filesystem and never looks under `build/packages`. Note
that it resolves them *relative to the package directory*, so a path escaping
the build's source root (`../client` from `./server`) cannot work in a sandbox
at all. That is a reason to structure the packages so it does not arise; gleam
reports it clearly enough when it does.

### `packages.toml` is an unspecified interface

Gleam decides a dependency is already on disk by reading
`build/packages/packages.toml`, and that format is read from gleam's behaviour
rather than from any specification. `checks.fetchGleamDeps-writes-the-index-gleam-reads`
pins it, so a gleam release that changes it fails here with the reason
attached, rather than in every consumer as a network attempt inside a sandbox
that has no network.

## `mkReleaseCommand`

A `release` command for a repository whose `main` is squash-merged with
conventional-commit subjects. It reads the version out of the commits since the
latest stable tag, renders `CHANGELOG.md` with git-cliff, shows you every merge
it read and waits for a literal `Y`, then commits, pushes `main`, tags, and
pushes the tag.

```nix
pkgs.mkReleaseCommand {
  repositoryUrl = "https://github.com/you/repo";  # builds the default cliff.toml
  hooks = ./ci/release-hooks.sh;                  # what this repo publishes
  cliffConfig = ./cliff.toml;                     # replaces repositoryUrl
  warmCommand = "warm-cache";                     # run the gate before pushing
  releaseWorkflow = "release.yml";                # wait for this run, report it
  watchTimeoutSeconds = 1800;                     # default
}
```

Every argument is optional, but one of `repositoryUrl` and `cliffConfig` has to
be there — the first builds the bundled `cliff.toml`, the second replaces it,
and passing neither throws at evaluation. Everything else absent means "this
repository does not do that": no hooks, no cache to warm, no workflow to wait
on.

The overlay carries three members:

- **`mkReleaseCommand`** — the builder above. The result is `bin/release`, plus
  `bin/release-hooks` when you supply hooks.
- **`releaseGuards`** — the same reading layer as its own package
  (`bin/release-guards`), for a CI job that has to re-check a tag someone
  pushed by hand. `bin/release` already has it on `PATH`.
- **`releaseGuardsTest`** — the guard suite as a derivation. Put it in your own
  `checks`; don't assume it passed here. Your repository pins its own dull-nix
  revision and resolves `bash`, `awk`, `sort` and `grep` through its own
  nixpkgs, and these are the checks that decide what you may publish.

```nix
checks.x86_64-linux.release-guards-hold = pkgs.releaseGuardsTest;
```

Three constraints, none of them configurable:

- **Releases run from `main`.** A clean checkout, level with `origin/main`,
  branch named `main`. Detached `HEAD`, a dirty tree, a stale clone, or any
  other branch is refused.
- **The changelog is `CHANGELOG.md`.** git-cliff rewrites it in full on every
  release, at the repository root, under that name.
- **A hooks script supplying one subcommand supplies all four.** There is no
  partial hooks script.

Everything it refuses, it refuses before anything exists: no tag, no commit, no
push. The one window where that stops being true is between the push of the
release commit and the tag — the guards are asked again there, and a refusal
leaves the release commit on `main` untagged with the version unspent.

### How the version is read

A `feat:` in the range asks for a minor; any other conventional type asks for a
patch; a `!` in the header or a `BREAKING CHANGE:` footer asks for a major. The
loudest wins.

- **Every conventional type is worth at least a patch**, not only `feat` and
  `fix`. A `docs:`-only range still has something to publish.
- **A derived `major` below `1.0` is served as a `minor`**, because a `0.x`
  minor bump already *is* the incompatible one under Cargo's and npm's rules.
  `release major`, typed deliberately, is the only path to `v1.0.0`.
- **A range in which no subject is conventional is refused, not guessed at.** A
  patch would be a version nobody chose, taken from subjects that are also
  about to become the changelog.

`release major|minor|patch` overrules the bump and `release vX.Y.Z` the whole
derivation. Prereleases have no derivation and are always named.

### The hooks are the whole repo-specific half

`mkReleaseCommand` knows nothing about what your repository publishes or which
file carries its version. A hooks script — dispatching on `$1`, exactly like
`release-guards` — supplies both.

**Supply one subcommand and you supply all four.** A repository with nothing to
check writes the no-op out; it does not leave the case to fall through. A hook
that is called and not implemented hits the usage arm, and a publish guard that
quietly does not run is worse than one that was never written.

| subcommand | when it runs | contract |
| --- | --- | --- |
| `assert-ready` | before any tag is read | non-zero refuses. Check the tools your other hooks need — this is the last point at which refusing costs nothing. |
| `describe VERSION` | building the summary | prints the lines shown above the confirmation and again on success. Nine-column labels (`printf '%-9s %s\n'`) line up with `commit` and `version`. |
| `assert-unpublished VERSION` | with the tag and ancestor guards | non-zero refuses. Ask your registry whether this version already exists. |
| `set-version VERSION` | preparing the release commit | writes the version wherever it belongs (without the `v`), then prints each path to stage, one per line. Print nothing if there is no version file. |

`release-guards` is on `PATH` for the hooks, so `describe` can ask
`release-guards is-stable "$VERSION"` whether a `:latest` pointer moves.

### `set-version` names the files; the driver stages them

`release` writes `CHANGELOG.md` and stages exactly one other thing: whatever
`set-version` printed. That is the only reason the release command has no
opinion about your version file.

- A **Rust workspace** runs
  `release-guards set-cargo-workspace-version "$1" <Cargo.toml` — which rewrites
  the `version` under `[workspace.package]` and nothing that merely looks like
  it — then `cargo update --workspace --offline`, and prints `Cargo.toml` and
  `Cargo.lock`.
- A **node package** runs `jq`, and prints `package.json`.
- A repository that publishes a container and **versions nothing on disk**
  prints nothing, and gets a release commit carrying `CHANGELOG.md` alone.

### A worked example, with no Rust in it

`fixtures/release-hooks/release-hooks.sh`, in full — the whole contract for a
node package. `checks.mkReleaseCommand-runs-repo-hooks` runs it.

```bash
#!/usr/bin/env bash
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
```

`assert-unpublished` is a `:` because this fixture publishes nothing — written
out, not omitted. `set-version` reads `package.json` into a variable before
writing it back, because a redirect would truncate the file before `jq` read
it. Wire it up with:

```nix
pkgs.mkReleaseCommand {
  repositoryUrl = "https://github.com/you/your-repo";
  hooks = ./ci/release-hooks.sh;
}
```

### `cliff.toml`

`release/cliff.toml` is the default, and `repositoryUrl` is what it needs: it
anchors every commit parser to the start of the subject (a `fix:` mid-sentence
is prose, not a type), and rewrites the trailing `(#N)` GitHub appends to a
squash subject into a pull-request link. That rewrite is a regex over text the
subject already carries — **not** `[remote.github]`, which resolves the same
links over the API and would put a token and a network call inside a release.

The type-to-section mapping in that file is a guess about your repository, not
a fact about it. Pass your own `cliffConfig` when the guess is wrong; you keep
the anchoring and the linking by copying them.

### What is *not* in here

The published artifact, the "is it already published" check, the workflow
watched with `gh`, the version-bearing files, and the cache-warming command.
Those are `hooks` and `warmCommand`. Adding any of them here would make this
package know about one repository.


## License

MIT. See [LICENSE](LICENSE).
