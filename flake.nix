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
    pkgsFor = system: extra:
      import nixpkgs {
        inherit system;
        config =
          if extra == "cuda"
          then {
            allowUnfree = true;
            cudaSupport = true;
          }
          else if extra == "rocm"
          then {
            allowUnfree = true;
            rocmSupport = true;
          }
          else {};
      };

    workspace = uv2nix.lib.workspace.loadWorkspace {workspaceRoot = ./.;};
    mkOverlay = extra:
      workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
        dependencies = {
          pri-1 = [extra];
        };
      };

    editableOverlay = workspace.mkEditablePyprojectOverlay {
      root = "$REPO_ROOT";
    };

    # ---------------------------------------------------------------------------
    # Package-specific fixups carried over from the pre-restructure flake.
    # Hardware-agnostic fixups apply to every variant (cpu/cuda/rocm).
    # CUDA-specific fixups (nvidia-* packages, torch's nvidia lib patching)
    # only apply when building the "cuda" extra, since those packages aren't
    # part of the dependency closure for cpu/rocm builds.
    # ---------------------------------------------------------------------------
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

    # Applies regardless of hardware extra
    nativeLibsCommon = pkgs: {
      numba = [pkgs.tbb];
      sounddevice = [pkgs.portaudio];
      soundfile = [pkgs.libsndfile];
    };

    # Only present in the dependency closure when the "cuda" extra is active.
    nativeLibsCuda = pkgs: {
      nvidia-cufile = [pkgs.rdma-core];
      nvidia-nvshmem-cu13 = with pkgs; [pmix libfabric openmpi ucx rdma-core];
    };

    # Only present in the dependency closure when the "rocm" extra is active.
    nativeLibsRocm = pkgs: {
      triton-rocm = with pkgs; [zlib zstd xz bzip2];
      torch = with pkgs; [zlib zstd xz bzip2];
    };

    allNativeLibs = pkgs: (lib.unique (lib.flatten (builtins.attrValues (nativeLibsCommon pkgs // nativeLibsCuda pkgs // nativeLibsRocm pkgs))));

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

    torchRocmLibOverlay = final: prev: {
      torch = prev.torch.overrideAttrs (old: {
        autoPatchelfIgnoreMissingDeps =
          (old.autoPatchelfIgnoreMissingDeps or [])
          ++ [
            "libamdhip64.so.7"
            "libhsa-runtime64.so.1"
            "libamd_comgr.so.3"
            "libhipblas.so.3"
            "libhipsparse.so.4"
            "libroctx64.so.4"
            "librocblas.so.5"
          ];
      });
    };

    mkPythonSet = system: extra: let
      pkgs = pkgsFor system extra;
      python = pkgs.python312;
    in
      (pkgs.callPackage pyproject-nix.build.packages {
        inherit python;
      }).overrideScope
      (
        lib.composeManyExtensions (
          [
            pyproject-build-systems.overlays.wheel
            (mkOverlay extra)
            buildSystemOverlay
            (mkNativeLibOverlay (nativeLibsCommon pkgs))
            (headerOverlay pkgs)
          ]
          ++ lib.optionals (extra == "cuda") [
            (mkNativeLibOverlay (nativeLibsCuda pkgs))
            nvidiaLibOverlay
            torchCudaLibOverlay
          ]
          ++ lib.optionals (extra == "rocm") [
            (mkNativeLibOverlay (nativeLibsRocm pkgs))
            torchRocmLibOverlay
          ]
        )
      );

    mkEnv = system: envName: deps: extra: let
      pythonSet =
        (mkPythonSet system extra)
      .overrideScope editableOverlay;
    in
      pythonSet.mkVirtualEnv envName
      (deps // {"pri-1" = [extra];});

    mkDevShell = system: extra: extraPkgs: let
      pkgs = pkgsFor system extra;
      pythonSet =
        (mkPythonSet system extra)
      .overrideScope editableOverlay;
      virtualenv =
        pythonSet.mkVirtualEnv
        "pri-1-dev-env"
        workspace.deps.default;
    in
      pkgs.mkShell {
        packages = [virtualenv pkgs.uv] ++ extraPkgs;
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
  in {
    # -------------------------------------------------------------------------
    # devShells
    #   nix develop            → CPU (default)
    #   nix develop .#cpu      → CPU
    #   nix develop .#cuda     → NVIDIA CUDA 13.2
    #   nix develop .#rocm     → AMD ROCm 7.2
    # -------------------------------------------------------------------------
    devShells = forAllSystems (
      system: {
        default = mkDevShell system "cpu" [];
        cpu = mkDevShell system "cpu" [];
        cuda = mkDevShell system "cuda" (with (pkgsFor system "cuda"); [cudaPackages.cudatoolkit]);
        rocm = mkDevShell system "rocm" (with (pkgsFor system "rocm"); [rocmPackages.clr rocmPackages.rocm-runtime]);
      }
    );

    # -------------------------------------------------------------------------
    # packages
    #   nix build              → CPU (default)
    #   nix build .#cpu        → CPU
    #   nix build .#cuda       → NVIDIA CUDA 13.2
    #   nix build .#rocm       → AMD ROCm 7.2
    # -------------------------------------------------------------------------
    packages = forAllSystems (
      system: {
        default = mkEnv system "pri-1-cpu-env" workspace.deps.default "cpu";
        cpu = mkEnv system "pri-1-cpu-env" workspace.deps.default "cpu";
        cuda = mkEnv system "pri-1-cuda-env" workspace.deps.default "cuda";
        rocm = mkEnv system "pri-1-rocm-env" workspace.deps.default "rocm";
      }
    );
  };
}
