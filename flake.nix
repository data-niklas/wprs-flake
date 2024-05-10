{
  description = "Build a cargo project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-analyzer-src.follows = "";
    };

    flake-utils.url = "github:numtide/flake-utils";

    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    crane,
    fenix,
    flake-utils,
    advisory-db,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      inherit (pkgs) lib;
      buildDeps = with pkgs; [
        pkg-config
        makeWrapper
        clang
        mold
      ];

      runtimeDeps = with pkgs;
        [
          libxkbcommon
          alsa-lib
          udev
          vulkan-loader
          wayland
          xwayland
          (python3.withPackages (pythonPackages:
            with pythonPackages; [
              psutil
            ]))
        ]
        ++ (with xorg; [
          libXcursor
          libXrandr
          libXi
          libX11
        ]);
      craneLib = crane.lib.${system};
      pname = "wprs";
      gitsrc = pkgs.fetchFromGitHub {
        owner = "wayland-transpositor";
        repo = "wprs";
        rev = "f9608b3f933409211b6d51b4477faf93de2924a4";
        sha256 = "sha256-UjJHAe5ijvBYSnRBWGU8dRarGloUdTIoTXO2lEnA1zA=";
      };
      patchedCargoLock = pkgs.stdenv.mkDerivation {
        src = gitsrc;
        name = "patch-cargo-lock";
        patches = [
          ./update-cargo-lock.patch
        ];
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp Cargo.lock $out
          runHook postInstall
        '';
      };
      src = lib.cleanSourceWith {
        src = gitsrc; # The original, unfiltered source
        filter = path: type:
          (builtins.match ".*wprs$" path != null) || (craneLib.filterCargoSources path type);
      };
      commonArgs = {
        inherit src;
        strictDeps = true;
        cargoVendorDir = craneLib.vendorCargoDeps {
          src = patchedCargoLock;
        };
        patches = [
          ./update-cargo-lock.patch
        ];

        nativeBuildInputs = buildDeps;
        buildInputs = runtimeDeps;
        doCheck = false;
      };

      craneLibLLvmTools =
        craneLib.overrideToolchain
        (fenix.packages.${system}.complete.withComponents [
          "cargo"
          "llvm-tools"
          "rustc"
        ]);

      cargoArtifacts = craneLib.buildDepsOnly commonArgs;

      wprs = craneLib.buildPackage (commonArgs
        // {
          inherit cargoArtifacts;
          postInstall = ''
            wrapProgram $out/bin/wprsc \
              --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath runtimeDeps}
            wrapProgram $out/bin/wprsd \
              --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath runtimeDeps}
            cp wprs $out/bin/
            chmod +x $out/bin/ wprs
          '';
        });
    in {
      packages = {
        wprs = wprs;
        default = wprs;
      };

      apps.default = flake-utils.lib.mkApp {
        drv = wprs;
      };

      devShells.default = craneLib.devShell {
        # Inherit inputs from checks.
        checks = self.checks.${system};
        LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath runtimeDeps}";
        packages = [
          # pkgs.ripgrep
        ];
      };
    });
}
