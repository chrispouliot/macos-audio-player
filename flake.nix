{
  description = "Native macOS audio player development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      #
      # Tell agent-sandbox that this project requires native macOS.
      #
      # This forces the Tart backend even if we later add Linux-compatible
      # tooling outputs to this flake.
      #
      agentSandbox.backend = "darwin";

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              # General development
              git
              just
              ripgrep
              jq

              # Declarative Xcode project generation
              xcodegen

              # Swift formatting
              swiftformat
            ];

            shellHook = ''
              echo
              echo "Native macOS Audio App Development"
              echo "System: ${system}"

              #
              # xcrun itself can exist without a usable full Xcode
              # installation, so verify the actual tools we need.
              #
              if ! xcrun --find xcodebuild >/dev/null 2>&1; then
                echo
                echo "ERROR: xcodebuild was not found."
                echo "A full Xcode installation must be selected."
                echo
                echo "Current developer directory:"
                xcode-select -p 2>/dev/null || echo "  none"
                echo
                return 1
              fi

              if ! xcrun --find swift >/dev/null 2>&1; then
                echo
                echo "ERROR: Swift was not found in the selected Xcode toolchain."
                return 1
              fi

              echo
              echo "Developer directory:"
              xcode-select -p

              echo
              echo "Xcode:"
              xcodebuild -version

              echo
              echo "Swift:"
              xcrun swift --version

              echo
              echo "macOS SDK:"
              xcrun --sdk macosx --show-sdk-path

              echo
              echo "XcodeGen:"
              xcodegen --version

              echo
              echo "Useful commands:"
              echo "  xcodegen generate"
              echo "  open *.xcodeproj"
              echo "  xcodebuild -scheme <Scheme> build"
              echo "  swiftformat ."
              echo
            '';
          };
        }
      );
    };
}
