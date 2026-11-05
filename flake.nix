{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs = {
        pyproject-nix.follows = "pyproject-nix";
        nixpkgs.follows = "nixpkgs";
      };
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs = {
        pyproject-nix.follows = "pyproject-nix";
        uv2nix.follows = "uv2nix";
        nixpkgs.follows = "nixpkgs";
      };
    };

    bombon = {
      url = "github:nikstur/bombon";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      bombon,
    }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      argsFor =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

          python = lib.head (
            pyproject-nix.lib.util.filterPythonInterpreters {
              inherit (workspace) requires-python;
              inherit (pkgs) pythonInterpreters;
            }
          );

          pythonSet = (pkgs.callPackage pyproject-nix.build.packages { inherit python; }).overrideScope (
            lib.composeManyExtensions [
              pyproject-build-systems.overlays.wheel
              (workspace.mkPyprojectOverlay { sourcePreference = "wheel"; })
              (final: prev: {
                presidio-analyzer = prev.presidio-analyzer.overrideAttrs (previousAttrs: {
                  src = presidioSource;
                  nativeBuildInputs =
                    previousAttrs.nativeBuildInputs ++ final.resolveBuildSystem { poetry-core = [ ]; };
                });
              })
            ]
          );

          presidioRev = lib.last (
            lib.splitString "#"
              (lib.findFirst (package: package.name == "presidio-analyzer") null
                (lib.importTOML ./uv.lock).package
              ).source.git
          );

          presidioSource = pkgs.fetchFromGitHub {
            owner = "microsoft";
            repo = "presidio";
            rev = presidioRev;
            hash = "sha256-YHwzEOFp4LbR0Hdh/qWvuw80LcVSff1OagL1KCHFM8w=";
          };
        in
        {
          inherit
            system
            pkgs
            pythonSet
            presidioRev
            presidioSource
            ;
          venv = pythonSet.mkVirtualEnv "presidio-analyzer-env" workspace.deps.default;
          imageSbom =
            package: extraPaths:
            pkgs.runCommand "${lib.getName package}-image-sbom"
              {
                __structuredAttrs = true;
                unsafeDiscardReferences.out = true;
                nativeBuildInputs = [ pkgs.cyclonedx-cli ];
                bom = bombon.lib.${system}.buildBom package { inherit extraPaths; };
              }
              ''
                mkdir $out
                cp "$bom" $out/sbom.cdx.json
                cyclonedx convert --input-file "$bom" --output-format spdxjson --output-file $out/sbom.spdx.json
              '';
        };
      forAllSystems = f: lib.genAttrs systems (system: f (argsFor system));
    in
    {
      devShells = forAllSystems (
        { pkgs, pythonSet, ... }:
        {
          default = pkgs.mkShell {
            packages = [
              pythonSet.python
              pkgs.uv
            ];
            env = {
              UV_NO_SYNC = "1";
              UV_PYTHON = pythonSet.python.interpreter;
              UV_PYTHON_DOWNLOADS = "never";
            };
            shellHook = ''
              unset PYTHONPATH
            '';
          };
        }
      );

      packages = forAllSystems (
        {
          pkgs,
          system,
          venv,
          presidioRev,
          presidioSource,
          imageSbom,
          ...
        }:
        let
          inherit (self.packages.${system}) presidio-analyzer;
          imageRuntime = with pkgs; [
            curl
            iana-etc
            tzdata
            dockerTools.binSh
            dockerTools.caCertificates
            dockerTools.usrBinEnv
            (dockerTools.fakeNss.override {
              extraPasswdLines = [ "presidio:x:1001:1001::/home/presidio:/bin/sh" ];
              extraGroupLines = [ "presidio:x:1001:" ];
            })
          ];
        in
        {
          default = presidio-analyzer;

          wikineural-multilingual-ner =
            let
              revision = "bed6ee7a45d2827b6c90a4fd7983f0241ae0a5c1";
              repository = "models--Babelscape--wikineural-multilingual-ner";
            in
            pkgs.linkFarm "wikineural-multilingual-ner" (
              [
                {
                  name = "${repository}/refs/main";
                  path = pkgs.writeText "main" revision;
                }
              ]
              ++
                lib.mapAttrsToList
                  (file: hash: {
                    name = "${repository}/snapshots/${revision}/${file}";
                    path = pkgs.fetchurl {
                      url = "https://huggingface.co/Babelscape/wikineural-multilingual-ner/resolve/${revision}/${file}";
                      inherit hash;
                    };
                  })
                  {
                    "config.json" = "sha256-i9bZxLqPzoRAeHancRCQNjJZMTu5Sj5a41DV9tKHCS8=";
                    "model.safetensors" = "sha256-NLPif7zQtUxFzAj/x7TgenowFIC2XNZDC7vTTaoA9qM=";
                    "special_tokens_map.json" = "sha256-MD30WgNgnk6tBLw9wVNtCrGbU1jbaFtvPaEj0F7CAOM=";
                    "tokenizer.json" = "sha256-URpcedG/j6OYykEanKm1coXl137TlQpPlHUfOVH0aWY=";
                    "tokenizer_config.json" = "sha256-Ns4aXTJUZWp19iEU9B7tjZv1f14QcUw6ITl4fK6E+3Q=";
                    "vocab.txt" = "sha256-/g/afEJbSMUW/I8WDVlMgCKggIRHR1wafG1keXY/MQw=";
                  }
            );

          presidio-analyzer = pkgs.stdenvNoCC.mkDerivation {
            pname = "presidio-analyzer";
            version = builtins.substring 0 7 presidioRev;
            src = presidioSource;
            sourceRoot = "${presidioSource.name}/presidio-analyzer";
            nativeBuildInputs = [ pkgs.makeWrapper ];
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              share=$out/share/presidio-analyzer
              mkdir -p $share/presidio_analyzer/conf
              cp app.py logging.ini $share/
              cp ${./overrides/presidio-analyzer/presidio_analyzer/conf}/*.yaml $share/presidio_analyzer/conf/
              makeWrapper ${venv}/bin/gunicorn $out/bin/presidio-analyzer \
                --chdir $share \
                --set-default PORT 3000 \
                --set-default WORKERS 1 \
                --set-default ANALYZER_CONF_FILE $share/presidio_analyzer/conf/default_analyzer.yaml \
                --set-default RECOGNIZER_REGISTRY_CONF_FILE $share/presidio_analyzer/conf/default_recognizers.yaml \
                --set-default NLP_CONF_FILE $share/presidio_analyzer/conf/transformers.yaml \
                --set-default HF_HUB_CACHE ${self.packages.${system}.wikineural-multilingual-ner} \
                --set-default HF_HUB_OFFLINE 1 \
                --add-flags '-w "$WORKERS" -b "0.0.0.0:$PORT" "app:create_app()"'
              runHook postInstall
            '';
            passthru = {
              inherit venv;
              bombonVendoredSbom =
                pkgs.runCommand "presidio-analyzer-uv-sbom"
                  {
                    nativeBuildInputs = [ pkgs.uv ];
                    env = {
                      UV_OFFLINE = "1";
                      UV_NO_CONFIG = "1";
                      UV_PYTHON_DOWNLOADS = "never";
                    };
                  }
                  ''
                    export UV_CACHE_DIR=$TMPDIR/uv
                    mkdir $out
                    uv export --project ${
                      lib.fileset.toSource {
                        root = ./.;
                        fileset = lib.fileset.unions [
                          ./pyproject.toml
                          ./uv.lock
                        ];
                      }
                    } --format cyclonedx1.5 --frozen --no-dev \
                      --preview-features sbom-export > $out/uv.cdx.json
                  '';
            };
            meta.mainProgram = "presidio-analyzer";
          };
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          presidio-analyzer-image = pkgs.dockerTools.streamLayeredImage {
            name = "stafftastic/presidio-analyzer";
            tag = "latest";
            contents = [ presidio-analyzer ] ++ imageRuntime;
            config = {
              User = "1001";
              WorkingDir = "/app";
              Cmd = [ "./entrypoint.sh" ];
              Env = [
                "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                "LANG=C.UTF-8"
                "PORT=3000"
                "WORKERS=1"
                "ANALYZER_CONF_FILE=presidio_analyzer/conf/default_analyzer.yaml"
                "RECOGNIZER_REGISTRY_CONF_FILE=presidio_analyzer/conf/default_recognizers.yaml"
                "NLP_CONF_FILE=presidio_analyzer/conf/transformers.yaml"
              ];
              ExposedPorts."3000/tcp" = { };
              Healthcheck = {
                Test = [
                  "CMD-SHELL"
                  "curl -f http://localhost:\${PORT}/health || exit 1"
                ];
                Interval = 30000000000;
                Timeout = 3000000000;
                StartPeriod = 30000000000;
                Retries = 3;
              };
            };
            fakeRootCommands = ''
              mkdir -m 1777 tmp
              mkdir -p app home/presidio usr/share
              cp -r ${presidio-analyzer}/share/presidio-analyzer/. app/
              install -m 755 ${pkgs.writeScript "entrypoint.sh" "#!/bin/sh\nexec presidio-analyzer \"$@\"\n"} app/entrypoint.sh
              chmod -R u+w app
              ln -s /share/zoneinfo usr/share/zoneinfo
              chown -R 1001:1001 app home/presidio
            '';
          };
          presidio-analyzer-image-sbom = imageSbom presidio-analyzer imageRuntime;
        }
      );

      checks = forAllSystems (
        {
          pkgs,
          system,
          pythonSet,
          ...
        }:
        {
          formatting = self.formatter.${system}.check self;
          nix-lint =
            pkgs.runCommandLocal "nix-lint"
              {
                nativeBuildInputs = with pkgs; [
                  deadnix
                  statix
                ];
              }
              ''
                cd ${self}
                statix check .
                deadnix --fail .
                touch $out
              '';
          uv-lock =
            pkgs.runCommandLocal "uv-lock"
              {
                nativeBuildInputs = [ pkgs.uv ];
                env = {
                  UV_OFFLINE = "1";
                  UV_PYTHON = pythonSet.python.interpreter;
                  UV_PYTHON_DOWNLOADS = "never";
                };
              }
              ''
                export UV_CACHE_DIR=$TMPDIR/uv
                cd ${self}
                uv lock --check
                touch $out
              '';
          actionlint =
            pkgs.runCommandLocal "actionlint"
              {
                nativeBuildInputs = with pkgs; [
                  actionlint
                  shellcheck
                ];
              }
              ''
                actionlint ${./.github/workflows}/*.yaml
                touch $out
              '';
          action-pins = pkgs.runCommandLocal "action-pins" { } ''
            unpinned=$(find ${./.github/workflows} -name '*.y*ml' -exec grep -nHE '^[[:space:]-]*uses:' {} + \
              | grep -vE '^[^:]+:[0-9]+:[[:space:]-]*uses:[[:space:]]+\./[^[:space:]]*[[:space:]]*$' \
              | grep -vE '^[^:]+:[0-9]+:[[:space:]-]*uses:[[:space:]]+[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} # [^[:space:]]+[[:space:]]*$' \
              | grep -vE '^[^:]+:[0-9]+:[[:space:]-]*uses:[[:space:]]+docker://[^[:space:]@#]+@sha256:[0-9a-f]{64}[[:space:]]*$' || true)
            if [ -n "$unpinned" ]; then
              echo "pin these as <action>@<commit> # <tag> (docker:// as @sha256:<digest>):"
              echo "$unpinned"
              exit 1
            fi
            touch $out
          '';
          ci-coverage =
            pkgs.runCommandLocal "ci-coverage"
              {
                checks = lib.concatLines (lib.attrNames self.checks.x86_64-linux);
                passAsFile = [ "checks" ];
              }
              ''
                grep -ohE '\.#checks\.x86_64-linux\.[A-Za-z0-9_-]+' ${./.github/workflows/pull-request.yaml} \
                  | sed 's/^\.#checks\.x86_64-linux\.//' | sort -u > built
                sort -u "$checksPath" > declared
                missing=$(comm -23 declared built)
                if [ -n "$missing" ]; then
                  echo "checks not built by any pull request job:" $missing
                  exit 1
                fi
                touch $out
              '';
          smoke =
            pkgs.runCommand "presidio-analyzer-smoke"
              {
                nativeBuildInputs = [
                  self.packages.${system}.default
                  pkgs.curl
                  pkgs.jq
                ];
                env.PORT = "3000";
                __darwinAllowLocalNetworking = true;
              }
              ''
                export HOME=$TMPDIR
                bash ${./test/smoke.sh}
                touch $out
              '';
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          image =
            pkgs.runCommand "presidio-analyzer-image-check"
              {
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                ${self.packages.${system}.presidio-analyzer-image} | tar -x
                jq -e '.config == {
                  User: "1001",
                  WorkingDir: "/app",
                  Cmd: ["./entrypoint.sh"],
                  Env: [
                    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                    "LANG=C.UTF-8",
                    "PORT=3000",
                    "WORKERS=1",
                    "ANALYZER_CONF_FILE=presidio_analyzer/conf/default_analyzer.yaml",
                    "RECOGNIZER_REGISTRY_CONF_FILE=presidio_analyzer/conf/default_recognizers.yaml",
                    "NLP_CONF_FILE=presidio_analyzer/conf/transformers.yaml"
                  ],
                  ExposedPorts: {"3000/tcp": {}},
                  Healthcheck: {
                    Test: ["CMD-SHELL", "curl -f http://localhost:''${PORT}/health || exit 1"],
                    Interval: 30000000000,
                    Timeout: 3000000000,
                    StartPeriod: 30000000000,
                    Retries: 3
                  }
                }' "$(jq -r '.[0].Config' manifest.json)"

                layer=$(jq -r '.[0].Layers[-1]' manifest.json)
                tar -tvf "$layer" --numeric-owner > listing
                grep -E '^drwx.* 1001/1001 .* \./app/$' listing
                grep -E '^drwx.* 1001/1001 .* \./home/presidio/$' listing
                grep -E '^drwxrwxrwt .* \./tmp/$' listing
                grep -E '^-rwxr-xr-x 1001/1001 .* \./app/entrypoint\.sh$' listing
                for file in app.py logging.ini default_analyzer.yaml default_recognizers.yaml transformers.yaml; do
                  grep -E "/$file\$" listing
                done

                mkdir root
                for layer in $(jq -r '.[0].Layers[]' manifest.json); do
                  tar -xf "$layer" -C root
                done
                grep -qx 'presidio:x:1001:1001::/home/presidio:/bin/sh' root/etc/passwd
                [ -x root/bin/presidio-analyzer ]
                [ -x root/bin/curl ]
                [ -x root/bin/sh ]
                [ -e root/etc/ssl/certs/ca-certificates.crt ]
                [ -e root/etc/services ]
                [ "$(readlink root/usr/share/zoneinfo)" = /share/zoneinfo ]
                [ -e root/share/zoneinfo/Europe/Berlin ]

                jq -e '[.. | .purl? | strings] as $purls
                  | ["pkg:pypi/presidio-analyzer@", "pkg:pypi/torch@", "pkg:pypi/transformers@", "pkg:pypi/de-core-news-sm@"]
                  | all(. as $prefix | $purls | any(startswith($prefix)))' \
                  ${self.packages.${system}.presidio-analyzer-image-sbom}/sbom.cdx.json
                jq -e '.packages | length > 0' ${
                  self.packages.${system}.presidio-analyzer-image-sbom
                }/sbom.spdx.json
                touch $out
              '';
        }
      );

      formatter = forAllSystems (
        { pkgs, ... }:
        pkgs.treefmt.withConfig {
          settings = {
            on-unmatched = "info";
            formatter = {
              nixfmt = {
                command = lib.getExe pkgs.nixfmt;
                includes = [ "*.nix" ];
              };
              oxfmt = {
                command = lib.getExe pkgs.oxfmt;
                includes = [
                  "*.yaml"
                  "*.yml"
                ];
              };
            };
          };
        }
      );
    };
}
