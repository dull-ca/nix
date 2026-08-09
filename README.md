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

## `mkReleaseCommand`

A `release` command for a repository whose `main` is squash-merged with
conventional-commit subjects. It reads the version out of the commits since the
latest stable tag, renders `CHANGELOG.md` with git-cliff, shows you every merge
it read and waits for a literal `Y`, then commits, pushes `main`, tags, and
pushes the tag.

```nix
pkgs.mkReleaseCommand {
  hooks = ./ci/release-hooks.sh;
  cliffConfig = ./cliff.toml;          # optional; needs repositoryUrl if omitted
  warmCommand = "warm-cache";          # optional
  releaseWorkflow = "release.yml";     # optional
  watchTimeoutSeconds = 1800;          # optional
}
```

The result is `bin/release`, plus `bin/release-hooks` when you supply hooks.
`pkgs.releaseGuards` is the same reading layer as its own package
(`bin/release-guards`) for a CI job that has to re-check a hand-pushed tag.

**It releases from `main` only**, from a clean checkout level with
`origin/main`. Everything it refuses, it refuses before anything exists: no
tag, no commit, no push. The one window where that stops being true is between
the push of the release commit and the tag — the guards are asked again there,
and a refusal leaves the release commit on `main` untagged with the version
unspent.

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
`release-guards` — supplies both. All four subcommands must exist; a repository
with nothing to do implements them as no-ops, because a silently skipped
publish guard is worse than none.

| subcommand | when it runs | contract |
| --- | --- | --- |
| `assert-ready` | before any tag is read | non-zero refuses. Check the tools your other hooks need — this is the last point at which refusing costs nothing. |
| `describe VERSION` | building the summary | prints the lines shown above the confirmation and again on success. Nine-column labels (`printf '%-9s %s\n'`) line up with `commit` and `version`. |
| `assert-unpublished VERSION` | with the tag and ancestor guards | non-zero refuses. Ask your registry whether this version already exists. |
| `set-version VERSION` | preparing the release commit | writes the version wherever it belongs (without the `v`), then prints each path to stage, one per line. Print nothing if there is no version file. |

`release-guards` is on `PATH` for the hooks, so `describe` can ask
`release-guards is-stable "$VERSION"` whether `:latest` moves.

A Rust workspace's `set-version` is
`release-guards set-cargo-workspace-version "$1" <Cargo.toml`, which rewrites
only the `version` under `[workspace.package]`, followed by `cargo update
--workspace --offline`, printing `Cargo.toml` and `Cargo.lock`. A bun or npm
package's is `jq '.version = $version'` printing `package.json` —
`fixtures/release-hooks/release-hooks.sh` is exactly that, and
`checks.mkReleaseCommand-runs-repo-hooks` runs it. A repository that publishes
a container and versions nothing on disk prints nothing and gets a release
commit carrying `CHANGELOG.md` alone.

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

