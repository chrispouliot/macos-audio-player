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

      appName = "ResumePlayer";
      scheme = "ResumePlayer";
      projectFile = "ResumePlayer.xcodeproj";
    in
    {
      #
      # This project requires the native macOS agent-sandbox backend
      # because it builds against Xcode and the macOS SDK.
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
              echo "Development:"
              echo "  xcodegen generate"
              echo "  open ${projectFile}"
              echo "  swiftformat ."

              echo
              echo "Build and run locally:"
              echo "  nix run .#run"

              echo
              echo "Build a Release version:"
              echo "  nix run .#build"

              echo
              echo "Install to ~/Applications:"
              echo "  nix run .#install"

              echo
            '';
          };
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };

          commonRuntimeInputs = with pkgs; [
            xcodegen
            coreutils
          ];

          runScript = pkgs.writeShellApplication {
            name = "run-${appName}";

            runtimeInputs = commonRuntimeInputs;

            text = ''
              set -euo pipefail

              if ! /usr/bin/xcrun --find xcodebuild >/dev/null 2>&1; then
                echo "ERROR: Full Xcode is not available."
                exit 1
              fi

              echo "Generating Xcode project..."
              xcodegen generate

              echo
              echo "Building ${appName} (Debug)..."

              /usr/bin/xcrun xcodebuild \
                -project "${projectFile}" \
                -scheme "${scheme}" \
                -configuration Debug \
                -derivedDataPath .derivedData \
                build

              APP="$PWD/.derivedData/Build/Products/Debug/${appName}.app"

              if [ ! -d "$APP" ]; then
                echo "ERROR: Build succeeded but app was not found:"
                echo "  $APP"
                exit 1
              fi

              echo
              echo "Launching:"
              echo "  $APP"

              /usr/bin/open "$APP"
            '';
          };

          buildScript = pkgs.writeShellApplication {
            name = "build-${appName}";

            runtimeInputs = commonRuntimeInputs;

            text = ''
              set -euo pipefail

              if ! /usr/bin/xcrun --find xcodebuild >/dev/null 2>&1; then
                echo "ERROR: Full Xcode is not available."
                exit 1
              fi

              echo "Generating Xcode project..."
              xcodegen generate

              echo
              echo "Building ${appName} (Release)..."

              /usr/bin/xcrun xcodebuild \
                -project "${projectFile}" \
                -scheme "${scheme}" \
                -configuration Release \
                -derivedDataPath .derivedData \
                build

              APP="$PWD/.derivedData/Build/Products/Release/${appName}.app"

              if [ ! -d "$APP" ]; then
                echo "ERROR: Build succeeded but app was not found:"
                echo "  $APP"
                exit 1
              fi

              echo
              echo "Release build:"
              echo "  $APP"
            '';
          };

          installScript = pkgs.writeShellApplication {
            name = "install-${appName}";

            runtimeInputs = commonRuntimeInputs;

            text = ''
              set -euo pipefail

              if ! /usr/bin/xcrun --find xcodebuild >/dev/null 2>&1; then
                echo "ERROR: Full Xcode is not available."
                exit 1
              fi

              echo "Generating Xcode project..."
              xcodegen generate

              echo
              echo "Building ${appName} (Release)..."

              /usr/bin/xcrun xcodebuild \
                -project "${projectFile}" \
                -scheme "${scheme}" \
                -configuration Release \
                -derivedDataPath .derivedData \
                build

              APP="$PWD/.derivedData/Build/Products/Release/${appName}.app"
              INSTALL_DIR="$HOME/Applications"
              DEST="$INSTALL_DIR/${appName}.app"

              if [ ! -d "$APP" ]; then
                echo "ERROR: Build succeeded but app was not found:"
                echo "  $APP"
                exit 1
              fi

              /bin/mkdir -p "$INSTALL_DIR"

              if [ -e "$DEST" ]; then
                echo "Removing previous installation..."
                /bin/rm -rf "$DEST"
              fi

              echo "Installing ${appName}..."
              /usr/bin/ditto "$APP" "$DEST"

              echo
              echo "Installed successfully:"
              echo "  $DEST"
              echo
              echo "Launch with:"
              echo "  open \"$DEST\""
              echo
              echo "or:"
              echo "  nix run .#run-installed"
            '';
          };

          runInstalledScript = pkgs.writeShellApplication {
            name = "run-installed-${appName}";

            text = ''
              set -euo pipefail

              APP="$HOME/Applications/${appName}.app"

              if [ ! -d "$APP" ]; then
                echo "${appName} is not installed."
                echo
                echo "Install it with:"
                echo "  nix run .#install"
                exit 1
              fi

              /usr/bin/open "$APP"
            '';
          };
        in
        {
          run = {
            type = "app";
            program = "${runScript}/bin/run-${appName}";
          };

          build = {
            type = "app";
            program = "${buildScript}/bin/build-${appName}";
          };

          install = {
            type = "app";
            program = "${installScript}/bin/install-${appName}";
          };

          run-installed = {
            type = "app";
            program = "${runInstalledScript}/bin/run-installed-${appName}";
          };

          default = {
            type = "app";
            program = "${runScript}/bin/run-${appName}";
          };
        }
      );
    };
}
