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
