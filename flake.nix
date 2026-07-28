{
  description = "An AI assistant for linux desktops";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    nixpkgs,
    pyproject-nix,
    uv2nix,
    pyproject-build-systems,
    ...
  }: let
    inherit (nixpkgs) lib;
    forAllSystems = lib.genAttrs lib.systems.flakeExposed;

    workspace = uv2nix.lib.workspace.loadWorkspace {workspaceRoot = ./.;};

    overlay = workspace.mkPyprojectOverlay {
      sourcePreference = "wheel";
    };

    editableOverlay = workspace.mkEditablePyprojectOverlay {
      root = "$REPO_ROOT";
    };

    mkBuildSystemOverlay = buildSystemOverrides: final: prev:
      builtins.mapAttrs (
        name: spec:
          prev.${name}.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or []) ++ final.resolveBuildSystem spec;
          })
      )
      buildSystemOverrides;

    buildSystemOverlay = mkBuildSystemOverlay {
      "antlr4-python3-runtime".setuptools = [];
      evdev.setuptools = [];
      "kaldi-python-io".setuptools = [];
      sox.setuptools = [];
      wget.setuptools = [];
    };

    mkNvidiaLibOverlay = overrides: final: prev:
      builtins.mapAttrs (
        name: depNames:
          prev.${name}.overrideAttrs (old: {
            buildInputs = (old.buildInputs or []) ++ map (d: final.${d}) depNames;
            preFixup =
              (old.preFixup or "")
              + lib.concatMapStrings (d: ''
                addAutoPatchelfSearchPath ${final.${d}}/lib/python3.12/site-packages/nvidia/cu13/lib
              '')
              depNames;
          })
      )
      overrides;

    nvidiaLibOverlay = mkNvidiaLibOverlay {
      nvidia-cusparse = ["nvidia-nvjitlink"];
      nvidia-cusolver = ["nvidia-cublas" "nvidia-cusparse" "nvidia-nvjitlink"];
    };
    mkNativeLibOverlay = nativeLibOverrides: final: prev:
      builtins.mapAttrs (
        name: libs:
          prev.${name}.overrideAttrs (old: {
            buildInputs = (old.buildInputs or []) ++ libs;
          })
      )
      nativeLibOverrides;

    nativeLibs = pkgs: {
      numba = [pkgs.tbb];
      nvidia-cufile = [pkgs.rdma-core];
      nvidia-nvshmem-cu13 = with pkgs; [pmix libfabric openmpi ucx rdma-core];
    };

    allNativeLibs = pkgs: (lib.unique (lib.flatten (builtins.attrValues (nativeLibs pkgs))));

    headerOverlay = pkgs: final: prev: {
      evdev = prev.evdev.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or []) ++ [pkgs.linuxHeaders];
        env =
          (old.env or {})
          // {
            CPATH = "${pkgs.linuxHeaders}/include";
          };
      });
    };

    torchCudaLibOverlay = final: prev: {
      torch = prev.torch.overrideAttrs (old: {
        preFixup =
          (old.preFixup or "")
          + ''
            ${lib.concatMapStrings (name: ''
              for d in ${final.${name}}/lib/python3.12/site-packages/nvidia/*/lib; do
                [ -d "$d" ] && addAutoPatchelfSearchPath "$d"
              done
            '') (builtins.filter (n: lib.hasPrefix "nvidia-" n) (builtins.attrNames final))}
          '';
        autoPatchelfIgnoreMissingDeps = ["libcuda.so.1"];
      });
    };

    pythonSets = forAllSystems (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        python = pkgs.python312;
      in
        (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
        }).overrideScope
        (
          lib.composeManyExtensions [
            pyproject-build-systems.overlays.wheel
            overlay
            buildSystemOverlay
            (mkNativeLibOverlay (nativeLibs pkgs))
            (headerOverlay pkgs)
            nvidiaLibOverlay
            torchCudaLibOverlay
          ]
        )
    );
  in {
    devShells = forAllSystems (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        pythonSet = pythonSets.${system}.overrideScope editableOverlay;
        virtualenv = pythonSet.mkVirtualEnv "pri-1-dev-env" workspace.deps.all;
      in {
        default = pkgs.mkShell {
          packages = [
            virtualenv
            pkgs.uv
          ];
          env = {
            UV_NO_SYNC = "1";
            UV_PYTHON = pythonSet.python.interpreter;
            UV_PYTHON_DOWNLOADS = "never";
          };
          shellHook = ''
            unset PYTHONPATH
            export REPO_ROOT=$(git rev-parse --show-toplevel)
            export LD_LIBRARY_PATH="/run/opengl-driver/lib:${lib.makeLibraryPath (allNativeLibs pkgs)}:$LD_LIBRARY_PATH"
          '';
        };
      }
    );

    packages = forAllSystems (system: {
      default = pythonSets.${system}.mkVirtualEnv "pri-1-env" workspace.deps.default;
    });
  };
}
