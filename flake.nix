{
  description = "Shared nix packages for dull-ca";

  # Repo-scoped cachix cache, same as golem (ADR 0035).
  nixConfig = {
    extra-substituters = [ "https://dull-ca.cachix.org" ];
    extra-trusted-public-keys = [
      "dull-ca.cachix.org-1:dRCsbIU6rWu2X/4+BOxwvtyVOHUXXmRp7ZmEXwne9bk="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    {
      overlays.default = final: prev: {
        # The nixpkgs-unstable this flake pins has buildNpmPackage/fetchNpmDeps
        # for npm and pnpm.fetchDeps for pnpm, but no bun equivalent --
        # buildBunPackage, bun.fetchDeps and bunConfigHook do not exist there.
        # fetchBunDeps is that missing piece, the same mechanism nixpkgs
        # blesses for npm, written once here so bun consumers get it the way
        # an npm project gets fetchNpmDeps. As with npmDepsHash on any
        # buildNpmPackage, every change to a consumer's bun.lock means bumping
        # its `hash` argument here.
        fetchBunDeps =
          { src
          , hash
          , pname ? "bun-deps"
          }:
          let
            # Only package.json and bun.lock decide what `bun install`
            # resolves, so only those two files are read into this
            # derivation's input. Anything else changing under `src` --
            # source code, unrelated fixture files -- must not force a
            # rebuild that hits the network.
            lockSrc = final.lib.cleanSourceWith {
              inherit src;
              name = "${pname}-lock-src";
              filter = path: type:
                type == "regular"
                && builtins.elem (baseNameOf path) [ "package.json" "bun.lock" ];
            };
          in
          final.stdenvNoCC.mkDerivation {
            inherit pname;
            version = "0";
            src = lockSrc;

            nativeBuildInputs = [ final.bun final.cacert ];

            buildPhase = ''
              runHook preBuild
              export HOME=$TMPDIR
              # stdenvNoCC's sandbox has no system CA trust store; without
              # this, bun's HTTPS requests to the registry fail certificate
              # verification outright.
              export SSL_CERT_FILE=${final.cacert}/etc/ssl/certs/ca-bundle.crt
              # No postinstall scripts run, so a dependency that needs one is
              # not supported by this builder. Also part of what keeps this
              # FOD hashable: a script could read the network, the clock, or
              # anything else outside package.json/bun.lock, and the output
              # hash would stop being reproducible.
              bun install --frozen-lockfile --no-progress --ignore-scripts
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              # Both are per-install bookkeeping bun writes that package.json
              # and bun.lock alone don't pin down. Left in, they would make
              # this FOD's output hash unreproducible between otherwise
              # identical builds.
              rm -rf node_modules/.cache
              find node_modules -name '.bun-tag*' -delete
              cp -r node_modules $out
              runHook postInstall
            '';

            dontFixup = true;
            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputHash = hash;
          };

        buildBunPackage =
          { src
          , bunDepsHash
          , buildScript ? "build"
          , installDir ? "dist"
          , nativeBuildInputs ? [ ]
          , buildInputs ? [ ]
          , passthru ? { }
          , ...
          }@args:
          let
            # No pname passed through: a fixed-output derivation's store path
            # is a function of (name, hashAlgo, hash) alone, never its src or
            # other inputs. Deriving this name from the caller's pname would
            # give two callers building the same bun.lock two different
            # bunDeps store paths instead of one shared one -- verified
            # directly by comparing outPaths with matching hashes and
            # differing pnames. Leaving it off lets fetchBunDeps's own
            # default pname keep every caller on the same path.
            bunDeps = final.fetchBunDeps {
              inherit src;
              hash = bunDepsHash;
            };

            forwarded = builtins.removeAttrs args [
              "bunDepsHash"
              "buildScript"
              "installDir"
              "nativeBuildInputs"
              "buildInputs"
              "passthru"
            ];
          in
          # forwarded is merged in last, so it wins over every attribute set
          # below -- a caller can override any of them, including phases.
          # A downstream repo relies on this to reuse buildBunPackage for a
          # check script by overriding installPhase outright, for a build
          # that produces no output directory to `cp -r`.
          final.stdenvNoCC.mkDerivation ({
            inherit src;
            # mkDerivation requires name, or pname + version; forwarded args
            # can still override this like any other default above.
            version = "0";

            # Appended to, not left for forwarded's `//` to replace outright:
            # a caller adding its own nativeBuildInputs/buildInputs/passthru
            # keeps bun, nodejs, autoPatchelfHook and bunDeps alongside its
            # own additions rather than losing them.
            nativeBuildInputs = [
              final.bun
              final.nodejs
              final.autoPatchelfHook
            ] ++ nativeBuildInputs;

            buildInputs = [ final.stdenv.cc.cc.lib ] ++ buildInputs;

            # bun installs *-linux-x64-musl builds of native deps alongside
            # the *-linux-x64-gnu ones this platform actually loads; the musl
            # ones are never loaded, so their libc dependency is never really
            # missing. Without this, autoPatchelf treats it as fatal instead
            # of ignorable: deleting this line fails the fixture build with
            # "auto-patchelf could not satisfy dependency
            # libc.musl-x86_64.so.1 wanted by
            # node_modules/lightningcss-linux-x64-musl/...".
            autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ];
            # autoPatchelfHook's own fixup-phase pass would scan $out after
            # install, but by then $out holds this package's build output
            # (JS/CSS here), not ELF -- there's nothing there to patch. What
            # needs patching is the deps tree, and it already was, explicitly,
            # in configurePhase below, before the build even ran.
            dontAutoPatchelf = true;

            configurePhase = ''
              runHook preConfigure
              cp -r ${bunDeps} node_modules
              chmod -R u+w node_modules
              autoPatchelf node_modules
              # Whole tree, not node_modules/.bin: .bin entries are symlinks,
              # and patchShebangs follows a symlink to patch the real file
              # underneath, so on this fixture either scope reaches the same
              # target and both pass -- this fixture does not prove the wider
              # scope necessary. It is necessary on the real dull.yyc.dev site
              # build: astro reaches node_modules/astro/astro.js by a relative
              # path, never through .bin, so patchShebangs node_modules/.bin
              # there leaves its "#!/usr/bin/env node" shebang unpatched and
              # the build dies with a bad interpreter.
              patchShebangs node_modules
              runHook postConfigure
            '';

            buildPhase = ''
              runHook preBuild
              export HOME=$TMPDIR
              bun run ${buildScript}
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              cp -r ${installDir} $out
              runHook postInstall
            '';

            # Exposes the fetched deps tree so a consumer needing the same
            # node_modules for something else -- e.g. running a lint/typecheck
            # against this package's deps -- can reuse it via
            # `<result>.bunDeps` instead of calling fetchBunDeps again with a
            # separately-tracked, duplicate hash.
            passthru = { inherit bunDeps; } // passthru;
          } // forwarded);
      };
    } // flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };
        static = pkgs.pkgsStatic;

        # Our own build of nginx, NOT an override of nixpkgs' package.
        #
        # `nginx.override` cannot produce this: generic.nix hardcodes an
        # unconditional module list (ssl, v3, xslt, dav, flv, mp4), the inner
        # `configureFlags` argument only appends, and nginx's configure has no
        # `--without-` for opt-in modules. So the build configuration is ours.
        #
        # But `src` and `version` are inherited, so nixpkgs still decides which
        # nginx we build and its security bumps reach us through a routine
        # `nix flake update` with no hash to hand-edit.
        nginx-static-no-tls = static.stdenv.mkDerivation {
          pname = "nginx-static-no-tls";
          inherit (pkgs.nginx) src version;

          buildInputs = [ static.pcre2 static.zlib ];
          nativeBuildInputs = [ pkgs.nukeReferences ];

          # The static stdenv adapter appends `--enable-static --disable-shared`,
          # which nginx's hand-rolled ./configure rejects outright. This suppresses
          # them. (It only works when set in the derivation's own args — setting it
          # through `overrideAttrs` on nixpkgs' nginx silently does nothing.)
          dontAddStaticConfigureFlags = true;

          # stdenv's generic configure phase otherwise adds `--prefix=$out`,
          # `--build=` and `--host=`; nginx rejects the autoconf platform flags.
          dontAddPrefix = true;
          configurePlatforms = [ ];

          configureFlags = [
            "--prefix=/etc/nginx"
            "--sbin-path=/bin/nginx"
            "--conf-path=/etc/nginx/nginx.conf"
            "--http-log-path=/dev/stdout"
            "--error-log-path=/dev/stderr"
            "--pid-path=/tmp/nginx.pid"
            "--http-client-body-temp-path=/tmp/client_body"
            "--with-http_gzip_static_module"
            # Included because this image is designed to sit behind a proxy;
            # without it every access log line shows the proxy's address.
            "--with-http_realip_module"
            "--with-threads"
            "--without-http_proxy_module"
            "--without-http_fastcgi_module"
            "--without-http_uwsgi_module"
            "--without-http_scgi_module"
            "--without-http_memcached_module"
            "--crossbuild=Linux::x86_64"
          ];

          # `make install` would try to create /etc/nginx inside the sandbox and
          # die on Permission denied. Copying objs/nginx directly also keeps the
          # store path out of the binary.
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/conf
            cp objs/nginx $out/bin/nginx
            cp conf/mime.types $out/conf/mime.types
            runHook postInstall
          '';

          # nuke-refs is safe only because the binary is statically linked: the
          # store paths it clears are dead strings in nginx's -V banner, not
          # runtime dependencies. Removing nix-support matters just as much —
          # its propagated-build-inputs file names the pcre2-dev and zlib-dev
          # paths and alone dragged the closure from 1.7 MB to 7.75 MB.
          postFixup = ''
            nuke-refs $out/bin/nginx
            rm -rf $out/nix-support
          '';

          meta = {
            description =
              "Statically linked nginx for static files, behind a TLS-terminating proxy";
            longDescription = ''
              Cannot serve HTTPS — ngx_http_ssl_module is not compiled in.
              Never expose this directly to the internet.
            '';
            platforms = [ "x86_64-linux" ];
          };
        };

        # The three headline properties below are the entire reason this
        # package exists rather than `pkgs.nginx`. Nothing about them is
        # self-evident from the build, and the weekly `update.yml` nixpkgs
        # bump can regress any of them silently -- so each is asserted as a
        # check that fails the gate.
        nginxClosure = pkgs.closureInfo { rootPaths = [ nginx-static-no-tls ]; };

        # A ceiling with headroom, not the exact 1,686,352 bytes the closure
        # measures today: an exact figure would turn every harmless nginx
        # point release into a red build. This is a tripwire for a structural
        # regression -- a reintroduced dynamic dependency or a restored
        # `nix-support` -- both of which are multi-megabyte jumps, not
        # kilobyte drift.
        closureSizeCeilingBytes = 2500000;

        # esbuild is statically linked and has no platform split, but its
        # bin/esbuild is a `#!/usr/bin/env node` script reached through a
        # node_modules/.bin symlink -- the shape a later shebang-patching
        # builder has to prove it can follow. lightningcss is what actually
        # resolves platform-split natives here: `bun install` against this
        # fixture yields both lightningcss-linux-x64-gnu and
        # lightningcss-linux-x64-musl, which the check below asserts.
        bunFixtureDeps = pkgs.fetchBunDeps {
          src = ./fixtures/bun-package;
          pname = "bun-fixture-deps";
          hash = "sha256-PaMiYRjIKk5QjvXhbvfVPSJNz2fhCIZuBT9SPOUo1rg=";
        };

        bunFixture = pkgs.buildBunPackage {
          pname = "bun-fixture";
          src = ./fixtures/bun-package;
          bunDepsHash = "sha256-PaMiYRjIKk5QjvXhbvfVPSJNz2fhCIZuBT9SPOUo1rg=";
        };
      in
      {
        packages = {
          inherit nginx-static-no-tls;
          default = nginx-static-no-tls;
        };

        checks = {
          # A binary that builds is not necessarily a binary that serves.
          nginx-static-no-tls-serves =
            pkgs.runCommand "nginx-static-no-tls-serves"
              { nativeBuildInputs = [ pkgs.curl ]; } ''
              mkdir -p root/sub conf
              echo '<h1>ok</h1>' > root/index.html
              echo '<h1>sub</h1>' > root/sub/index.html
              echo 'body{}' > root/app.css

              cat > conf/nginx.conf <<EOF
              daemon off;
              error_log stderr crit;
              pid $PWD/nginx.pid;
              events { worker_connections 64; }
              http {
                include ${nginx-static-no-tls}/conf/mime.types;
                default_type application/octet-stream;
                access_log off;
                server {
                  listen 8399;
                  root $PWD/root;
                  location / { try_files \$uri \$uri/index.html \$uri/ =404; }
                }
              }
              EOF

              ${nginx-static-no-tls}/bin/nginx -c $PWD/conf/nginx.conf &
              nginx_pid=$!
              for i in $(seq 1 50); do
                curl -sf -o /dev/null http://127.0.0.1:8399/ && break
                sleep 0.2
              done

              code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8399/)
              ctype=$(curl -s -o /dev/null -w '%{content_type}' http://127.0.0.1:8399/)
              clean=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8399/sub)
              css=$(curl -s -o /dev/null -w '%{content_type}' http://127.0.0.1:8399/app.css)
              missing=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8399/nope)

              kill $nginx_pid || true

              test "$code" = 200 || { echo "FAIL root: $code"; exit 1; }
              test "$ctype" = "text/html" || { echo "FAIL ctype: $ctype"; exit 1; }
              test "$clean" = 200 || { echo "FAIL clean url: $clean"; exit 1; }
              test "$css" = "text/css" || { echo "FAIL css: $css"; exit 1; }
              test "$missing" = 404 || { echo "FAIL 404: $missing"; exit 1; }

              echo "all assertions passed" > $out
            '';

          # Zero store references is what lets a consumer copy this one path
          # into a container from an empty base. A single reintroduced
          # reference drags its whole transitive closure along and the image
          # stops being ~2 MB.
          #
          # With no references the closure is exactly the package itself, so
          # `store-paths` minus that one line must be empty.
          nginx-static-no-tls-has-zero-store-references =
            pkgs.runCommand "nginx-static-no-tls-has-zero-store-references" { } ''
              references=$(grep -Fxv '${nginx-static-no-tls}' ${nginxClosure}/store-paths || true)

              if [ -n "$references" ]; then
                echo "FAIL: expected zero store references, found:"
                echo "$references"
                exit 1
              fi

              echo "zero store references" > $out
            '';

          nginx-static-no-tls-closure-within-budget =
            pkgs.runCommand "nginx-static-no-tls-closure-within-budget" { } ''
              ceiling=${toString closureSizeCeilingBytes}
              actual=$(cat ${nginxClosure}/total-nar-size)
              echo "closure is $actual bytes; ceiling is $ceiling bytes"

              if [ "$actual" -gt "$ceiling" ]; then
                echo "FAIL: closure exceeds the ceiling by $((actual - ceiling)) bytes."
                echo "Something reintroduced a dependency -- check the reference"
                echo "assertion above and postFixup before raising this number."
                exit 1
              fi

              echo "$actual" > $out
            '';

          # The `-no-tls` in the package name is a safety claim, and this is
          # what makes it a tested one. Both outcomes are asserted: nginx must
          # reject an `ssl` listener, AND reject it specifically for the
          # missing module -- a config broken some other way would otherwise
          # pass this check while TLS was quietly compiled back in.
          nginx-static-no-tls-rejects-ssl-listener =
            pkgs.runCommand "nginx-static-no-tls-rejects-ssl-listener" { } ''
              printf 'daemon off;\nevents {}\nhttp { server { listen 8397 ssl; } }\n' \
                > ssl-probe.conf

              if ${nginx-static-no-tls}/bin/nginx -t -c $PWD/ssl-probe.conf 2> probe.log; then
                echo "FAIL: nginx ACCEPTED an ssl listener -- ngx_http_ssl_module"
                echo "is compiled in and the package name is now a lie."
                cat probe.log
                exit 1
              fi

              if ! grep -q 'the "ssl" parameter requires ngx_http_ssl_module' probe.log; then
                echo "FAIL: the ssl config was rejected, but not for the absence"
                echo "of ngx_http_ssl_module -- this check is no longer testing TLS:"
                cat probe.log
                exit 1
              fi

              cp probe.log $out
            '';

          # bun installs *-linux-x64-musl native packages alongside the
          # *-linux-x64-gnu ones that actually load on this platform. A later
          # builder relies on that by ignoring the missing musl libc
          # (autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ]). If
          # bun ever stops installing the musl variant, that exclusion goes
          # silently dead and starts hiding a genuinely missing dependency
          # instead of a harmless one. This check is the tripwire: it fails
          # the moment a real `bun install` stops producing a musl variant,
          # rather than leaving that assumption unverified in the builder.
          #
          # It is also the one check in this flake that depends on the npm
          # registry -- an accepted trade, not an oversight. Without it, a
          # regression in the bun builder only shows up as a downstream
          # repo's red CI, and the weekly update.yml nixpkgs bump has no way
          # to report that it broke the builder.
          bun-fixture-deps-contain-platform-split-natives =
            pkgs.runCommand "bun-fixture-deps-contain-platform-split-natives" { } ''
              gnu=$(ls ${bunFixtureDeps} | grep -E 'linux-x64-gnu$' || true)
              musl=$(ls ${bunFixtureDeps} | grep -E 'linux-x64-musl$' || true)

              echo "gnu variants: $gnu"
              echo "musl variants: $musl"

              if [ -z "$gnu" ]; then
                echo "FAIL: no *-linux-x64-gnu package in the deps tree."
                exit 1
              fi

              if [ -z "$musl" ]; then
                echo "FAIL: no *-linux-x64-musl package in the deps tree."
                exit 1
              fi

              echo "$gnu $musl" > $out
            '';

          # Each assertion targets a way the fixture build could silently do
          # nothing instead of the real work: no bundle.js (the bundler never
          # ran), a bundle without the fixture's own source string (stale or
          # empty output slipping past the first check), no style.css (the
          # native lightningcss module never loaded -- autoPatchelf or
          # patchShebangs regressed), and, the one a passing build could
          # otherwise still hide, style.css still containing the unminified
          # `rgb(0, 0, 0)` -- proof the native module loaded but did no work.
          buildBunPackage-builds-fixture =
            pkgs.runCommand "buildBunPackage-builds-fixture" { } ''
              if [ ! -f ${bunFixture}/bundle.js ]; then
                echo "FAIL: esbuild produced no bundle.js -- the bundler never ran."
                ls -R ${bunFixture}
                exit 1
              fi

              if ! grep -q 'buildBunPackage works' ${bunFixture}/bundle.js; then
                echo "FAIL: bundle.js does not contain the fixture source string."
                cat ${bunFixture}/bundle.js
                exit 1
              fi

              if [ ! -f ${bunFixture}/style.css ]; then
                echo "FAIL: lightningcss produced no style.css -- the native"
                echo "module never loaded."
                ls -R ${bunFixture}
                exit 1
              fi

              if grep -q 'rgb(0, 0, 0)' ${bunFixture}/style.css; then
                echo "FAIL: style.css is not minified -- lightningcss ran but did"
                echo "no work."
                cat ${bunFixture}/style.css
                exit 1
              fi

              cat ${bunFixture}/style.css > $out
            '';
        };
      });
}
