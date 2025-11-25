{
  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
      argsFor = system: {
        pkgs = nixpkgs.legacyPackages.${system};
      };
      forAllSystems = f: lib.genAttrs systems (system: f (argsFor system));
    in
    {
      packages = forAllSystems (
        { pkgs, ... }:
        {
          default =
            let
              rev = "a47837b20a747d2a4c636da3b93026b5188884f0";
              shortRev = builtins.substring 0 7 rev;
              src =
                pkgs.runCommand "presidio-source"
                  {
                    src = pkgs.fetchFromGitHub {
                      inherit rev;
                      repo = "presidio";
                      owner = "microsoft";
                      hash = "sha256-YHwzEOFp4LbR0Hdh/qWvuw80LcVSff1OagL1KCHFM8w=";
                    };
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
                -t stafftastic/presidio-analyzer:${shortRev}-${self.shortRev or self.dirtyShortRev or "unknown"} \
                "$@"
            '';
        }
      );

      formatter = forAllSystems (
        { pkgs, ... }:
        pkgs.treefmt.withConfig {
          settings = {
            on-unmatched = "info";
            formatter.nixfmt = {
              command = lib.getExe pkgs.nixfmt-rfc-style;
              includes = [ "*.nix" ];
            };
          };
        }
      );
    };
}
