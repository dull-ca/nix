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
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
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
        };
      });
}
