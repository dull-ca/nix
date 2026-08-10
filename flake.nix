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

        # The gleam equivalent of fetchBunDeps above -- with one difference
        # worth the paragraph, because the asymmetry between the two is
        # otherwise going to read as an oversight.
        #
        # `manifest.toml` is a complete lockfile: gleam records an
        # `outer_checksum` for every hex package, and that checksum *is* the
        # SHA-256 of the tarball hex serves. Every hash this fetch needs is
        # therefore already in a file gleam maintains, so there is no
        # fixed-output derivation here and no `gleamDepsHash` for anyone to
        # bump. Adding a dependency updates `manifest.toml` and that is the
        # whole of it. fetchBunDeps needs its hash because bun's lockfile
        # offers no equivalent, not because this one is cutting a corner.
        #
        # Only `source = "hex"` entries are fetched. A `local` path dependency
        # is resolved by gleam straight from the filesystem and never looked for
        # here, so omitting it is correct; if its path escapes the build's
        # source root, gleam says so itself and by name. A `git` dependency has
        # no checksum in the manifest and cannot be fetched purely, so it is
        # refused outright rather than left to fail later as a sandbox with no
        # network.
        fetchGleamDeps =
          { manifest
          , pname ? "gleam-deps"
          }:
          let
            inherit (final) lib;

            parsed = builtins.fromTOML (builtins.readFile manifest);
            packages = parsed.packages or [ ];
            fromSource = source: builtins.filter (p: p.source == source) packages;

            gitPackages = fromSource "git";
            hexPackages = lib.sort (a: b: a.name < b.name) (fromSource "hex");

            refuseGitPackages =
              throw ''
                fetchGleamDeps cannot fetch the git dependencies in ${toString manifest}:
                  ${lib.concatMapStringsSep "\n  " (p: p.name) gitPackages}
                A git source carries no checksum in manifest.toml, so there is
                nothing to verify a fetch against. Depend on a hex release, or
                vendor the package as a local path dependency.
              '';

            # `outer_checksum` is upper-case hex; nix wants it lower-case.
            tarballFor = p: final.fetchurl {
              url = "https://repo.hex.pm/tarballs/${p.name}-${p.version}.tar";
              sha256 = lib.toLower p.outer_checksum;
            };

            # A hex tarball is an outer tar holding `contents.tar.gz`, and it is
            # that inner archive gleam expects unpacked under the package name.
            unpack = p: ''
              mkdir -p "$out/${p.name}"
              tar -xf ${tarballFor p} -C "$TMPDIR/outer" contents.tar.gz
              tar -xzf "$TMPDIR/outer/contents.tar.gz" -C "$out/${p.name}"
              rm "$TMPDIR/outer/contents.tar.gz"
            '';

            # How gleam decides a package is already present and skips the
            # network. Written sorted so the file does not vary between
            # otherwise identical builds -- gleam's own copy is emitted in hash
            # order and would.
            index = lib.concatMapStrings (p: "${p.name} = \"${p.version}\"\n") hexPackages;
          in
          if gitPackages != [ ] then refuseGitPackages else
          final.runCommand pname { } ''
            mkdir -p "$out" "$TMPDIR/outer"
            ${lib.concatMapStrings unpack hexPackages}
            cat > "$out/packages.toml" <<'PACKAGES'
            [packages]
            ${index}
            [git]
            PACKAGES
            touch "$out/gleam.lock"
          '';

        # Compiles a gleam package with its dependencies already on disk, so the
        # build needs no network. `target` picks what comes out: an
        # `erlang-shipment` ready to run under `erl`, or the compiled javascript
        # tree for a bundler to take from.
        #
        # rebar3 and gnumake are unconditional. Plenty of gleam packages depend
        # on a hex package written in erlang, gleam shells out to rebar3 to
        # build those, and a builder that lacks it fails only in whichever
        # consumer first needs it.
        #
        # Unrecognised arguments are forwarded to mkDerivation and merged last,
        # so a caller can replace `buildPhase`/`installPhase` outright -- which
        # is how a consumer runs `gleam test` or `gleam format --check` against
        # this same dependency tree instead of resolving a second one.
        buildGleamPackage =
          { pname
          , src
          , version ? "0"
          , target ? "erlang"
          , manifest ? src + "/manifest.toml"
          , erlang ? final.beam27Packages.erlang
          , nativeBuildInputs ? [ ]
          , passthru ? { }
          , ...
          }@args:
          let
            gleamDeps = final.fetchGleamDeps {
              inherit manifest;
              pname = "${pname}-deps";
            };

            forwarded = builtins.removeAttrs args [
              "target"
              "manifest"
              "erlang"
              "nativeBuildInputs"
              "passthru"
            ];

            targets = {
              erlang = {
                build = "gleam export erlang-shipment";
                install = "build/erlang-shipment";
              };
              javascript = {
                build = "gleam build --target javascript";
                install = "build/dev/javascript";
              };
            };

            chosen = targets.${target} or (throw
              "buildGleamPackage: target must be \"erlang\" or \"javascript\", not \"${target}\"");
          in
          final.stdenvNoCC.mkDerivation ({
            inherit pname version src;

            nativeBuildInputs = [
              final.gleam
              erlang
              final.rebar3
              final.gnumake
            ] ++ nativeBuildInputs;

            # Copied rather than symlinked: gleam writes into build/packages
            # while it works, and a store path is read-only.
            configurePhase = ''
              runHook preConfigure
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME" build
              cp -r ${gleamDeps} build/packages
              chmod -R u+w build/packages
              runHook postConfigure
            '';

            buildPhase = ''
              runHook preBuild
              ${chosen.build}
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              cp -r ${chosen.install} "$out"
              runHook postInstall
            '';

            # The output is compiled BEAM or javascript. Nothing here is an ELF
            # binary for the usual fixup to strip, patch or shrink.
            dontFixup = true;

            # `<result>.gleamDeps`, for a check that compiles the same source a
            # second way without fetching the tree again.
            passthru = { inherit gleamDeps; } // passthru;
          } // forwarded);

        releaseGuards = final.runCommand "release-guards"
          {
            meta.mainProgram = "release-guards";
          } ''
          mkdir -p $out/bin
          install -m 0755 ${./release/release-guards.sh} $out/bin/release-guards
          patchShebangs $out/bin
        '';

        # Handed to consumers as a check they run, not a result they inherit.
        # `checks.release-guards-hold` below proves the guards hold under this
        # repository's nixpkgs at this revision; a consumer pins a dull-nix
        # revision of its own and resolves bash, awk, sort and grep through a
        # nixpkgs of its own, and the guards decide what that repository may
        # publish. Cheap enough that every consumer running it is the right
        # trade against any of them trusting a run it did not do.
        releaseGuardsTest = final.runCommand "release-guards-hold"
          {
            nativeBuildInputs = [ final.bash ];
          } ''
          bash ${./release/release-guards.test.sh} \
            ${final.releaseGuards}/bin/release-guards
          touch $out
        '';

        # `bin/release`, wrapped so the repo-specific half travels in the
        # environment and the script itself stays free of any one repository.
        # `hooks`, `warmCommand` and `releaseWorkflow` default to null, which
        # reaches release.sh as an empty string meaning "this repository does
        # not do that". One of `repositoryUrl` and `cliffConfig` is required --
        # the throw below is the only argument error this builder can raise. The
        # release branch and `CHANGELOG.md` are not arguments at all; see
        # release.sh.
        #
        # `hooks` is installed rather than pointed at where nix put it: a file
        # copied to the store lands read-only and non-executable, and `release`
        # runs it as a command. `install -m 0755` plus `patchShebangs` is what
        # makes it one.
        mkReleaseCommand =
          { hooks ? null
          , cliffConfig ? null
          , repositoryUrl ? null
          , warmCommand ? null
          , releaseWorkflow ? null
          , watchTimeoutSeconds ? 1800
          }:
          let
            inherit (final) lib;

            generatedCliffConfig =
              if repositoryUrl == null then
                throw ''
                  mkReleaseCommand needs a repositoryUrl to build the default
                  cliff.toml from, or a cliffConfig of its own.
                ''
              else
                final.runCommand "cliff.toml" { } ''
                  substitute ${./release/cliff.toml} $out \
                    --replace-fail '@repositoryUrl@' '${repositoryUrl}'
                '';

            resolvedCliffConfig =
              if cliffConfig != null then cliffConfig else generatedCliffConfig;
          in
          final.runCommand "release"
            {
              nativeBuildInputs = [ final.makeWrapper ];
              # Exposed because the substituted config is otherwise unreachable
              # -- a caller who passed no `cliffConfig` has no name for the one
              # it got. `checks.default-cliff-config-renders` renders through
              # this.
              passthru.cliffConfig = resolvedCliffConfig;
              meta.mainProgram = "release";
            } ''
            mkdir -p $out/bin
            install -m 0755 ${./release/release.sh} $out/bin/release
            ${lib.optionalString (hooks != null) ''
              install -m 0755 ${hooks} $out/bin/release-hooks
            ''}
            patchShebangs $out/bin

            wrapProgram $out/bin/release \
              --prefix PATH : ${final.releaseGuards}/bin \
              --set RELEASE_CLIFF_CONFIG ${resolvedCliffConfig} \
              --set RELEASE_WATCH_TIMEOUT_SECONDS ${toString watchTimeoutSeconds} \
              --set RELEASE_HOOKS ${
                if hooks == null then "''" else "$out/bin/release-hooks"
              } \
              --set RELEASE_WARM_COMMAND ${
                if warmCommand == null then "''" else lib.escapeShellArg warmCommand
              } \
              --set RELEASE_WORKFLOW ${
                if releaseWorkflow == null then "''" else lib.escapeShellArg releaseWorkflow
              }
          '';
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

        gleamFixtureDeps = pkgs.fetchGleamDeps {
          manifest = ./fixtures/gleam-package/manifest.toml;
          pname = "gleam-fixture-deps";
        };

        # Carries thoas, which rebar3 builds, so this exercises both compilers.
        gleamFixtureShipment = pkgs.buildGleamPackage {
          pname = "gleam-fixture";
          src = ./fixtures/gleam-package;
        };

        gleamJsFixture = pkgs.buildGleamPackage {
          pname = "gleam-js-fixture";
          src = ./fixtures/gleam-js-package;
          target = "javascript";
        };

        # Backs buildGleamPackage-forwards-and-merges-caller-args. Replacing
        # both phases is the documented way a consumer runs `gleam test` or
        # `gleam format --check` against an already-resolved dependency tree,
        # so it is the merge behaviour that most needs holding.
        gleamPackageMergeProbe = pkgs.buildGleamPackage {
          pname = "buildGleamPackage-merge-probe";
          src = ./fixtures/gleam-package;
          nativeBuildInputs = [ pkgs.hello ];
          passthru = { gleamPackageProbeMarker = "buildGleamPackage-merge-probe-marker"; };
          buildPhase = ''
            runHook preBuild
            gleam format --check src
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            echo buildGleamPackage-merge-probe-install-ran > $out
            runHook postInstall
          '';
        };

        # A consumer with no Rust in it: the hooks write package.json, and the
        # cliff.toml comes from the shared default rather than a per-repo one.
        releaseFixture = pkgs.mkReleaseCommand {
          repositoryUrl = "https://github.com/dull-ca/release-fixture";
          hooks = ./fixtures/release-hooks/release-hooks.sh;
        };
      in
      {
        packages = {
          inherit nginx-static-no-tls;
          release-guards = pkgs.releaseGuards;
          default = nginx-static-no-tls;
        };

        checks = {
          release-guards-hold = pkgs.releaseGuardsTest;

          # packages.toml is how gleam decides a dependency is already on disk
          # and skips the network. Its format is read from gleam's behaviour
          # rather than from any specification, so it is asserted here: if a
          # future gleam changes it, this fails with the reason attached
          # instead of every consumer failing as an unexplained network attempt
          # inside a sandbox.
          fetchGleamDeps-writes-the-index-gleam-reads =
            pkgs.runCommand "fetchGleamDeps-writes-the-index-gleam-reads" { } ''
              index=${gleamFixtureDeps}/packages.toml
              cat "$index"

              grep -Fqx '[packages]' "$index" \
                || { echo "FAIL: no [packages] table"; exit 1; }
              grep -Fqx '[git]' "$index" \
                || { echo "FAIL: no [git] table -- gleam writes one even when empty"; exit 1; }
              grep -Fqx 'gleam_stdlib = "1.0.5"' "$index" \
                || { echo "FAIL: the hex package is not indexed at its locked version"; exit 1; }
              grep -Fqx 'thoas = "1.2.1"' "$index" \
                || { echo "FAIL: the rebar3 package is not indexed"; exit 1; }

              # Sorted, so the file cannot vary between identical builds.
              packages=$(sed -n '/^\[packages\]$/,/^\[git\]$/p' "$index" \
                | grep ' = ' | cut -d' ' -f1)
              [ "$packages" = "$(printf '%s\n' "$packages" | sort)" ] \
                || { echo "FAIL: the index is not in sorted order"; exit 1; }

              test -f ${gleamFixtureDeps}/gleam_stdlib/gleam.toml \
                || { echo "FAIL: the package contents were not unpacked"; exit 1; }
              test -f ${gleamFixtureDeps}/gleam.lock \
                || { echo "FAIL: no gleam.lock"; exit 1; }

              touch $out
            '';

          # gleam resolves a path dependency from the filesystem, so the tree
          # must leave it out rather than fail trying to fetch something that
          # has no checksum and no url.
          fetchGleamDeps-skips-local-path-dependencies =
            let
              deps = pkgs.fetchGleamDeps {
                manifest = ./fixtures/gleam-manifests/with-local-path.toml;
                pname = "gleam-local-path-deps";
              };
            in
            pkgs.runCommand "fetchGleamDeps-skips-local-path-dependencies" { } ''
              test -d ${deps}/gleam_stdlib \
                || { echo "FAIL: the hex package beside the path dependency was dropped"; exit 1; }

              if [ -e ${deps}/a_sibling_package ]; then
                echo "FAIL: a local path dependency was fetched into the tree"
                exit 1
              fi
              if grep -q a_sibling_package ${deps}/packages.toml; then
                echo "FAIL: a local path dependency was written into packages.toml"
                exit 1
              fi

              touch $out
            '';

          # Evaluated, never built: the refusal is a `throw`, so the failure has
          # to be caught at evaluation time.
          fetchGleamDeps-refuses-git-dependencies =
            let
              attempt = builtins.tryEval (pkgs.fetchGleamDeps {
                manifest = ./fixtures/gleam-manifests/with-git-dependency.toml;
                pname = "gleam-git-deps";
              }).outPath;
            in
            pkgs.runCommand "fetchGleamDeps-refuses-git-dependencies" { } ''
              ${pkgs.lib.optionalString attempt.success ''
                echo "FAIL: a git dependency evaluated instead of being refused."
                echo "Nothing verifies such a fetch, so it must not be attempted."
                exit 1
              ''}
              touch $out
            '';

          # A package that compiles is not necessarily a package that runs, and
          # the shipment is what the container actually executes.
          buildGleamPackage-erlang-shipment-runs =
            pkgs.runCommand "buildGleamPackage-erlang-shipment-runs"
              { nativeBuildInputs = [ pkgs.beam27Packages.erlang ]; } ''
              # thoas is compiled by rebar3 and by nothing else in this build,
              # so its beam reaching the shipment is the assertion that gleam
              # found a working rebar3.
              test -f ${gleamFixtureShipment}/thoas/ebin/thoas.beam \
                || { echo "FAIL: the rebar3-built dependency never compiled"; exit 1; }

              erl -pa ${gleamFixtureShipment}/*/ebin \
                -eval 'gleam_fixture@@main:run(gleam_fixture)' -noshell > out.log

              grep -Fqx 'GLEAM-FIXTURE-RAN' out.log \
                || { echo "FAIL: the shipment did not run its main:"; cat out.log; exit 1; }

              cp out.log $out
            '';

          buildGleamPackage-javascript-target-runs =
            pkgs.runCommand "buildGleamPackage-javascript-target-runs"
              { nativeBuildInputs = [ pkgs.nodejs ]; } ''
              cat > run.mjs <<'ENTRY'
              import { main } from "${gleamJsFixture}/gleam_js_fixture/gleam_js_fixture.mjs";
              main();
              ENTRY

              node run.mjs > out.log

              grep -Fqx 'GLEAM-JS-FIXTURE-RAN' out.log \
                || { echo "FAIL: the built javascript did not run:"; cat out.log; exit 1; }

              cp out.log $out
            '';

          # Replacing both phases is how a consumer reuses the resolved tree for
          # a test or format run, so caller arguments have to survive the merge
          # rather than be overwritten by the builder's own.
          buildGleamPackage-forwards-and-merges-caller-args =
            pkgs.runCommand "buildGleamPackage-forwards-and-merges-caller-args" { } ''
              grep -Fqx 'buildGleamPackage-merge-probe-install-ran' ${gleamPackageMergeProbe} \
                || { echo "FAIL: the caller's installPhase did not replace the builder's"; exit 1; }

              [ '${gleamPackageMergeProbe.gleamPackageProbeMarker}' \
                = 'buildGleamPackage-merge-probe-marker' ] \
                || { echo "FAIL: the caller's passthru was lost"; exit 1; }

              # The builder's own inputs must survive the caller adding theirs:
              # without gleam the replaced buildPhase above could not have run.
              [ -n '${toString (builtins.elem pkgs.hello gleamPackageMergeProbe.nativeBuildInputs)}' ] \
                || { echo "FAIL: the caller's nativeBuildInputs were dropped"; exit 1; }
              ${pkgs.lib.optionalString
                (!builtins.elem pkgs.gleam gleamPackageMergeProbe.nativeBuildInputs) ''
                echo "FAIL: the builder's own gleam was replaced by the caller's inputs"
                exit 1
              ''}

              touch $out
            '';

          # The version-bearing file is the consumer's business, so the builder
          # is only correct if a hook it never heard of can carry it. This one
          # is package.json and jq -- no Cargo anywhere.
          mkReleaseCommand-runs-repo-hooks =
            pkgs.runCommand "mkReleaseCommand-runs-repo-hooks"
              { nativeBuildInputs = [ pkgs.jq ]; } ''
              cp ${./fixtures/release-hooks/package.json} package.json
              chmod u+w package.json

              described=$(${releaseFixture}/bin/release-hooks describe v1.2.3)
              echo "describe: $described"
              case "$described" in
                *"0.1.0 -> 1.2.3"*) ;;
                *)
                  echo "FAIL: describe did not report the version transition."
                  exit 1
                  ;;
              esac

              staged=$(${releaseFixture}/bin/release-hooks set-version 1.2.3)
              if [ "$staged" != "package.json" ]; then
                echo "FAIL: set-version named '$staged' as the file to stage,"
                echo "so the release commit would not carry package.json."
                exit 1
              fi

              written=$(jq -r .version package.json)
              if [ "$written" != "1.2.3" ]; then
                echo "FAIL: package.json still reads $written -- set-version wrote nothing."
                cat package.json
                exit 1
              fi

              echo "hooks carried the version into package.json" > $out
            '';

          # Reached through the wrapper, so a broken RELEASE_* setting or a
          # release-guards that fell off PATH fails here rather than during
          # someone's release.
          release-refuses-a-dirty-tree =
            pkgs.runCommand "release-refuses-a-dirty-tree"
              { nativeBuildInputs = [ pkgs.git pkgs.git-cliff ]; } ''
              export HOME=$TMPDIR
              git init --quiet --initial-branch=main repo
              cd repo
              git config user.email fixture@example.com
              git config user.name fixture
              echo one > file
              git add file
              git commit --quiet -m 'feat: a thing'
              echo two > file

              if ${releaseFixture}/bin/release > out.log 2>&1; then
                echo "FAIL: release accepted a dirty working tree."
                cat out.log
                exit 1
              fi

              if ! grep -q 'the working tree is dirty' out.log; then
                echo "FAIL: release refused, but not for the dirty tree -- something"
                echo "earlier in the wrapper is broken:"
                cat out.log
                exit 1
              fi

              cp out.log $out
            '';

          # The default cliff.toml is only a default if it renders. Asserts the
          # repositoryUrl reached both the commit link and the (#N) rewrite,
          # and that the parsers still sort commits into sections.
          default-cliff-config-renders =
            pkgs.runCommand "default-cliff-config-renders"
              { nativeBuildInputs = [ pkgs.git pkgs.git-cliff ]; } ''
              if grep -q '@repositoryUrl@' ${releaseFixture.cliffConfig}; then
                echo "FAIL: the cliff.toml template still holds its placeholder."
                exit 1
              fi

              export HOME=$TMPDIR
              git init --quiet --initial-branch=main repo
              cd repo
              git config user.email fixture@example.com
              git config user.name fixture
              echo one > file && git add file
              git commit --quiet -m 'feat(scope): the first thing (#7)'
              echo two > file && git add file
              git commit --quiet -m 'fix: the second thing'
              echo three > file && git add file
              git commit --quiet -m 'chore(release): v0.0.1'

              git-cliff --config ${releaseFixture.cliffConfig} --tag v0.1.0 \
                --unreleased --strip header > rendered.md
              cat rendered.md

              grep -q '^### Features' rendered.md \
                || { echo "FAIL: no Features section"; exit 1; }
              grep -q '^### Fixes' rendered.md \
                || { echo "FAIL: no Fixes section"; exit 1; }
              grep -q '\*\*scope\*\*' rendered.md \
                || { echo "FAIL: the scope was dropped"; exit 1; }
              grep -qF '[#7](https://github.com/dull-ca/release-fixture/pull/7)' rendered.md \
                || { echo "FAIL: the (#N) suffix was not linked"; exit 1; }
              grep -qF '(https://github.com/dull-ca/release-fixture/commit/' rendered.md \
                || { echo "FAIL: the commit link is missing"; exit 1; }
              if grep -q 'chore(release)' rendered.md; then
                echo "FAIL: the release commit was not skipped"
                exit 1
              fi

              cp rendered.md $out
            '';

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
