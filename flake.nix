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
  };

  outputs =
    {
      self,
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
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
          ...
        }:
        {
          default = self.packages.${system}.presidio-analyzer;

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
                --add-flags '-w "$WORKERS" -b "0.0.0.0:$PORT" "app:create_app()"'
              runHook postInstall
            '';
            passthru = { inherit venv; };
            meta.mainProgram = "presidio-analyzer";
          };

          docker-build =
            let
              src =
                pkgs.runCommand "presidio-source"
                  {
                    src = presidioSource;
                  }
                  ''
                    cp -r $src tmp
                    chmod -R u+rwX tmp
                    cp -r ${./overrides}/. tmp
                    pushd tmp
                    patch -up1 < ${./patches/remove-cache.patch}
                    popd
                    cp -r tmp $out
                  '';
            in
            pkgs.writeShellScriptBin "build" ''
              docker buildx build ${src}/presidio-analyzer \
                -f ${src}/presidio-analyzer/Dockerfile.transformers \
                -t stafftastic/presidio-analyzer:${builtins.substring 0 7 presidioRev}-${
                  self.shortRev or self.dirtyShortRev or "unknown"
                } \
                "$@"
            '';
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
                actionlint -config-file ${./.github/actionlint.yaml} ${./.github/workflows}/*.yaml
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
          package = self.packages.${system}.default;
          smoke =
            pkgs.runCommand "presidio-analyzer-smoke"
              {
                nativeBuildInputs = [
                  self.packages.${system}.default
                  pkgs.curl
                  pkgs.jq
                ];
                env = {
                  PORT = "3000";
                  NLP_CONF_FILE = "${./test/nlp-spacy.yaml}";
                  HF_HUB_OFFLINE = "1";
                };
                __darwinAllowLocalNetworking = true;
              }
              ''
                export HOME=$TMPDIR
                bash ${./test/smoke.sh}
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
