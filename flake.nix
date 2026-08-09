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
        # bun equivalent of fetchNpmDeps (nixpkgs-unstable has none yet). Like
        # npmDepsHash, `hash` needs bumping whenever a consumer's bun.lock changes.
        fetchBunDeps =
          { src
          , hash
          , pname ? "bun-deps"
          }:
          let
            # Only these two files affect what `bun install` resolves; anything
            # else under `src` must not force a network-hitting rebuild.
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
              # stdenvNoCC has no system CA trust store; without this, bun's
              # HTTPS requests to the registry fail cert verification.
              export SSL_CERT_FILE=${final.cacert}/etc/ssl/certs/ca-bundle.crt
              # --ignore-scripts: no dependency postinstall runs (unsupported by
              # this builder), which also keeps the FOD hash reproducible.
              bun install --frozen-lockfile --no-progress --ignore-scripts
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              # Per-install bookkeeping bun writes; left in, they'd make this
              # FOD's output hash unreproducible between identical builds.
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
            # No pname forwarded: an FOD's store path depends only on
            # (name, hashAlgo, hash), so leaving it off keeps every caller
            # building the same bun.lock on one shared bunDeps path.
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
          # forwarded merges in last, so a caller can override any attribute
          # below, including phases (used downstream to override installPhase
          # outright for a build with no output dir to `cp -r`).
          final.stdenvNoCC.mkDerivation ({
            inherit src;
            version = "0";

            # Appended, not replaced by forwarded's `//`, so a caller's own
            # nativeBuildInputs/buildInputs/passthru add to these rather than
            # losing bun, nodejs, autoPatchelfHook and bunDeps.
            nativeBuildInputs = [
              final.bun
              final.nodejs
              final.autoPatchelfHook
            ] ++ nativeBuildInputs;

            buildInputs = [ final.stdenv.cc.cc.lib ] ++ buildInputs;

            # bun installs musl-linux-x64 native builds alongside the gnu ones
            # this platform loads; musl's libc dep is never actually missing,
            # just never loaded. Without this, autoPatchelf treats it as fatal:
            # "could not satisfy dependency libc.musl-x86_64.so.1".
            autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ];
            # $out holds JS/CSS by the time autoPatchelfHook's fixup pass would
            # run, not ELF; the deps tree is patched explicitly below instead.
            dontAutoPatchelf = true;

            configurePhase = ''
              runHook preConfigure
              cp -r ${bunDeps} node_modules
              chmod -R u+w node_modules
              autoPatchelf node_modules
              # Whole tree, not node_modules/.bin: this fixture can't prove the
              # wider scope necessary (.bin entries are symlinks patchShebangs
              # follows anyway), but the real dull.yyc.dev site build needs it --
              # astro reaches node_modules/astro/astro.js by a relative path,
              # never through .bin, and a narrower scan leaves its shebang
              # unpatched with a bad interpreter.
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

            # Exposes the deps tree via `<result>.bunDeps` for e.g. lint/typecheck
            # against the same node_modules, without re-fetching under a second hash.
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

        # Own build, not nginx.override: generic.nix hardcodes a module list
        # nginx's ./configure has no flag to unset. src/version still come
        # from pkgs.nginx, so nixpkgs' security bumps still reach us.
        nginx-static-no-tls = static.stdenv.mkDerivation {
          pname = "nginx-static-no-tls";
          inherit (pkgs.nginx) src version;

          buildInputs = [ static.pcre2 static.zlib ];
          nativeBuildInputs = [ pkgs.nukeReferences ];

          # Suppresses the static adapter's --enable-static --disable-shared,
          # which nginx's ./configure rejects. Must be set here, not via
          # overrideAttrs on nixpkgs' nginx (that silently does nothing).
          dontAddStaticConfigureFlags = true;

          # nginx rejects the autoconf platform flags (--prefix, --build, --host)
          # stdenv's generic configure phase would otherwise add.
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
            # Behind a proxy, without this every access log line shows the proxy's address.
            "--with-http_realip_module"
            "--with-threads"
            "--without-http_proxy_module"
            "--without-http_fastcgi_module"
            "--without-http_uwsgi_module"
            "--without-http_scgi_module"
            "--without-http_memcached_module"
            "--crossbuild=Linux::x86_64"
          ];

          # `make install` would create /etc/nginx inside the sandbox and die on
          # Permission denied; copy objs/nginx directly instead.
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/conf
            cp objs/nginx $out/bin/nginx
            cp conf/mime.types $out/conf/mime.types
            runHook postInstall
          '';

          # Safe only because the binary is static (nuke-refs clears dead strings
          # from -V, not runtime deps). nix-support's propagated-build-inputs
          # alone dragged the closure from 1.7 MB to 7.75 MB.
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

        # Backs the checks below, which guard the properties an nginx bump
        # could silently regress.
        nginxClosure = pkgs.closureInfo { rootPaths = [ nginx-static-no-tls ]; };

        # Headroom above today's 1,686,352 bytes, not that exact figure --
        # a tripwire for a structural regression (multi-megabyte), not
        # kilobyte drift from a routine nginx point release.
        closureSizeCeilingBytes = 2500000;

        # Exercises both a symlinked .bin shebang (esbuild) and platform-split
        # natives (lightningcss, asserted by the check below).
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

        # Backs buildBunPackage-forwards-and-merges-caller-args, below.
        # fakeHash is fine: that check only reads drvAttrs/passthru, never
        # forces bunDeps to build.
        bunPackageMergeProbe = pkgs.buildBunPackage {
          pname = "buildBunPackage-merge-probe";
          src = ./fixtures/bun-package;
          bunDepsHash = pkgs.lib.fakeHash;
          nativeBuildInputs = [ pkgs.hello ];
          buildInputs = [ pkgs.jq ];
          passthru = { buildBunPackageProbeMarker = "buildBunPackage-merge-probe-marker"; };
          installPhase = ''
            runHook preInstall
            echo buildBunPackage-merge-probe-install-ran > $out
            runHook postInstall
          '';
        };

        # Backs buildBunPackage-bunDeps-stable-across-pname: same src and
        # bunDepsHash, pname is the only difference under test.
        bunPackageStabilityProbeA = pkgs.buildBunPackage {
          pname = "buildBunPackage-stability-probe-a";
          src = ./fixtures/bun-package;
          bunDepsHash = pkgs.lib.fakeHash;
        };

        bunPackageStabilityProbeB = pkgs.buildBunPackage {
          pname = "buildBunPackage-stability-probe-b-different-name";
          src = ./fixtures/bun-package;
          bunDepsHash = pkgs.lib.fakeHash;
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

          # Zero references is what lets a consumer copy this path alone into
          # an empty-base container; one reintroduced reference drags its
          # whole closure along.
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

          # Asserts both the rejection AND its cause (missing module) -- a
          # config broken some other way would otherwise pass this check
          # while TLS was quietly compiled back in.
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

          # Tripwire for autoPatchelfIgnoreMissingDeps above: if bun ever stops
          # installing the musl variant, that exclusion goes silently dead.
          # Depends on the npm registry -- the one non-hermetic check here,
          # accepted so a builder regression doesn't surface only as a
          # downstream repo's red CI.
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

          # Each assertion catches the build silently doing nothing instead of
          # real work: missing bundle.js, stale output, missing style.css
          # (native module never loaded), or unminified CSS (loaded but ran).
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

          # Asserts the merge/override behavior a downstream repo depends on:
          # caller args win, and nativeBuildInputs/buildInputs/passthru merge
          # rather than replace. bunPackageMergeProbe exercises one caller
          # argument per property.
          buildBunPackage-forwards-and-merges-caller-args =
            let
              nativeBuildInputNames =
                map (d: d.pname or d.name) bunPackageMergeProbe.drvAttrs.nativeBuildInputs;
              buildInputNames =
                map (d: d.pname or d.name) bunPackageMergeProbe.drvAttrs.buildInputs;
              hasCallerPassthruMarker =
                (bunPackageMergeProbe.buildBunPackageProbeMarker or null)
                == "buildBunPackage-merge-probe-marker";
              hasBuilderPassthruBunDeps = bunPackageMergeProbe ? bunDeps;
              installPhaseOverridden =
                bunPackageMergeProbe.drvAttrs.installPhase == ''
                  runHook preInstall
                  echo buildBunPackage-merge-probe-install-ran > $out
                  runHook postInstall
                '';
            in
            pkgs.runCommand "buildBunPackage-forwards-and-merges-caller-args" {
              nativeBuildInputNames = toString nativeBuildInputNames;
              buildInputNames = toString buildInputNames;
              hasCallerPassthruMarker = if hasCallerPassthruMarker then "true" else "false";
              hasBuilderPassthruBunDeps = if hasBuilderPassthruBunDeps then "true" else "false";
              installPhaseOverridden = if installPhaseOverridden then "true" else "false";
            } ''
              for name in bun nodejs auto-patchelf-hook hello; do
                case " $nativeBuildInputNames " in
                  *" $name "*) ;;
                  *)
                    echo "FAIL: nativeBuildInputs is missing '$name' -- caller-supplied"
                    echo "nativeBuildInputs is replacing the builder's own list instead of"
                    echo "being appended to it. Got: $nativeBuildInputNames"
                    exit 1
                    ;;
                esac
              done

              for name in gcc jq; do
                case " $buildInputNames " in
                  *" $name "*) ;;
                  *)
                    echo "FAIL: buildInputs is missing '$name' -- caller-supplied buildInputs"
                    echo "is replacing the builder's own list instead of being appended to"
                    echo "it. Got: $buildInputNames"
                    exit 1
                    ;;
                esac
              done

              if [ "$hasCallerPassthruMarker" != "true" ]; then
                echo "FAIL: a caller-supplied passthru attribute did not survive --"
                echo "passthru is replacing the builder's own attrset instead of being"
                echo "merged with it."
                exit 1
              fi

              if [ "$hasBuilderPassthruBunDeps" != "true" ]; then
                echo "FAIL: passthru.bunDeps is gone once a caller supplies its own"
                echo "passthru -- callers can no longer reuse the deps tree via"
                echo "<result>.bunDeps."
                exit 1
              fi

              if [ "$installPhaseOverridden" != "true" ]; then
                echo "FAIL: a caller-supplied installPhase did not win over the builder's"
                echo "default installPhase -- forwarded caller args are no longer merged"
                echo "in last."
                exit 1
              fi

              echo "caller args merge and override correctly" > $out
            '';

          # Two calls with the same src and bunDepsHash but different pname
          # must resolve to the same bunDeps path (see bunDeps above), or two
          # consumers of the identical bun.lock silently stop sharing one.
          buildBunPackage-bunDeps-stable-across-pname =
            let
              # Discards string context so comparing these paths doesn't force
              # a real build of the fakeHash-hashed FOD (which would fail).
              aBunDepsPath =
                builtins.unsafeDiscardStringContext bunPackageStabilityProbeA.bunDeps.outPath;
              bBunDepsPath =
                builtins.unsafeDiscardStringContext bunPackageStabilityProbeB.bunDeps.outPath;
            in
            pkgs.runCommand "buildBunPackage-bunDeps-stable-across-pname" {
              inherit aBunDepsPath bBunDepsPath;
            } ''
              if [ "$aBunDepsPath" != "$bBunDepsPath" ]; then
                echo "FAIL: two buildBunPackage calls with the same src and bunDepsHash"
                echo "but different pname produced different bunDeps store paths:"
                echo "  $aBunDepsPath"
                echo "  $bBunDepsPath"
                echo "This means fetchBunDeps's pname is being derived from the caller's"
                echo "pname again, which breaks reuse of a shared deps tree across"
                echo "callers building the same bun.lock."
                exit 1
              fi

              echo "bunDeps stable across pname: $aBunDepsPath" > $out
            '';
        };
      });
}
