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

A `buildNpmPackage`-equivalent for bun: fetches `bun.lock`-pinned dependencies
as a fixed-output derivation with no build-time network access, then runs the
package's build script against them.

Wire it up via the overlay, then call it exactly like `pkgs.buildNpmPackage`:

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
the common case. Everything else forwards straight to `mkDerivation`, and a
caller's own `nativeBuildInputs`, `buildInputs` and `passthru` are merged
alongside the builder's, not replaced by them — add your own without losing
`bun`, `nodejs` or `autoPatchelfHook`.

### Why this exists, not `buildNpmPackage` or `pnpm.fetchDeps`

The nixpkgs-unstable this flake pins has `buildNpmPackage`/`fetchNpmDeps` for
npm and `pnpm.fetchDeps` for pnpm. It has no bun equivalent —
`buildBunPackage`, `bun.fetchDeps` and `bunConfigHook` don't exist there. This
isn't a different approach from what nixpkgs already blesses: `fetchNpmDeps`
is itself a fixed-output derivation with a hash the caller bumps by hand, the
same mechanism `fetchBunDeps` uses for bun. It's just unwritten upstream.
`fetchBunDeps` and `buildBunPackage` fill that gap here so a bun project gets
what an npm project already has.

### The standing cost: bumping `bunDepsHash`

`fetchBunDeps` is keyed on `hash`. Anything that changes what `bun install`
resolves — a `bun.lock` edit, almost always — invalidates it, and
`bunDepsHash` has to be bumped by hand. This is identical to what
`npmDepsHash` imposes on every `buildNpmPackage` in nixpkgs; it is the price
of the fetch step being allowed to touch the network at all.

Get the new value by setting `bunDepsHash` to `pkgs.lib.fakeHash`, building,
and reading the mismatch nix reports:

```
$ nix build .#packages.x86_64-linux.<your-package>
error: hash mismatch in fixed-output derivation '.../bun-deps-0.drv':
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            got:    sha256-PaMiYRjIKk5QjvXhbvfVPSJNz2fhCIZuBT9SPOUo1rg=
```

Paste the `got:` value back in as `bunDepsHash`. (The value above is real —
reproduced directly against this repo's own `fixtures/bun-package` while
writing this section, not a placeholder.)

### What it can't build

`fetchBunDeps` runs `bun install --ignore-scripts`, so no postinstall step
ever runs. A dependency whose postinstall does real work, not just an
optional nicety, fails at build time rather than fetch time.

The concrete case: `lightningcss-cli`'s `node_modules/.bin/lightningcss` is
npm's placeholder text file ("This file is required so that npm creates the
lightningcss binary on Windows.") until its own `postinstall.js` copies the
real platform binary over it. Skip that script and the build reaches `bun run
build` only to fail:

```
node_modules/.bin/lightningcss: line 1: This: command not found
```

This repo's own fixture hit exactly that. The fix was switching the fixture
to depend on `lightningcss` — the library, which resolves its native module
at `require` time and needs no postinstall — rather than teaching the builder
to run lifecycle scripts. `--ignore-scripts` stays: it's also what keeps
`fetchBunDeps`'s output hashable, since a postinstall that reads the network
or the clock would make the fixed-output hash unreproducible.

### Two settings that look removable but aren't

`autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ]` — bun installs
the `-musl` build of every native dependency alongside the `-gnu` one this
platform actually loads. The musl copy's libc dependency is never really
missing, just never loaded. Delete the exclusion and `autoPatchelf` treats it
as fatal instead:

```
auto-patchelf could not satisfy dependency libc.musl-x86_64.so.1
```

`patchShebangs node_modules` scans the whole dependency tree, not just
`node_modules/.bin`. On this repo's own fixture the narrower scan doesn't
actually fail — `.bin` entries are symlinks, and `patchShebangs` follows a
symlink to patch the real file underneath, so either scope reaches the same
target here. It does fail on the real dull.yyc.dev site build: Astro reaches
`node_modules/astro/astro.js` by a relative path, never through `.bin`, so the
narrow scan leaves its `#!/usr/bin/env node` shebang unpatched and the build
dies with a bad interpreter. This repo's fixture can't prove the whole-tree
scan necessary — the site build is why it stays anyway.

### The fixture check reaches the npm registry

`checks.buildBunPackage-builds-fixture` runs a real `bun install` against a
committed fixture project — the one check in this flake that isn't hermetic.
That's deliberate: without it, a regression in `buildBunPackage` only ever
shows up as a downstream repo's red CI, and the weekly `nix flake update` PR
that [keeps `nginx-static-no-tls`
patched](#how-security-updates-reach-this-package) would have no way to
report that the same nixpkgs bump broke this builder too.
