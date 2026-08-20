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
      # This is a native macOS/Xcode project.
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
              git
              just
              ripgrep
              jq

              xcodegen
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
              if [ -n "''${AGENT_DERIVED_DATA_PATH:-}" ]; then
                echo "DerivedData:"
                echo "  $AGENT_DERIVED_DATA_PATH"
                echo "  (private agent-sandbox cache)"
              else
                echo "DerivedData:"
                echo "  $HOME/Library/Caches/${appName}/DerivedData"
                echo "  (private host cache)"
              fi

              echo
              echo "Development:"
              echo "  xcodegen generate"
              echo "  open ${projectFile}"
              echo "  swiftformat ."

              echo
              echo "Build and run locally:"
              echo "  nix run"
              echo "  nix run .#run"

              echo
              echo "Build a Release version:"
              echo "  nix run .#build"

              echo
              echo "Package a Release DMG:"
              echo "  nix run .#dmg"

              echo
              echo "Install to ~/Applications:"
              echo "  nix run .#install"

              echo
              echo "Run the installed app:"
              echo "  nix run .#run-installed"

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

          #
          # agent-sandbox provides AGENT_DERIVED_DATA_PATH.
          #
          # Normal host builds fall back to a cache belonging entirely
          # to the logged-in macOS user.
          #
          derivedDataSetup = ''
            DERIVED_DATA="''${AGENT_DERIVED_DATA_PATH:-$HOME/Library/Caches/${appName}/DerivedData}"

            /bin/mkdir -p "$DERIVED_DATA"

            echo "DerivedData:"
            echo "  $DERIVED_DATA"
            echo
          '';

          checkXcode = ''
            if ! /usr/bin/xcrun --find xcodebuild >/dev/null 2>&1; then
              echo "ERROR: Full Xcode is not available." >&2
              exit 1
            fi
          '';

          runScript = pkgs.writeShellApplication {
            name = "run-${appName}";

            runtimeInputs = commonRuntimeInputs;

            text = ''
              set -euo pipefail

              ${checkXcode}
              ${derivedDataSetup}

              echo "Generating Xcode project..."
              xcodegen generate

              echo
              echo "Building ${appName} (Debug)..."

              /usr/bin/xcrun xcodebuild \
                -project "${projectFile}" \
                -scheme "${scheme}" \
                -configuration Debug \
                -derivedDataPath "$DERIVED_DATA" \
                build

              APP="$DERIVED_DATA/Build/Products/Debug/${appName}.app"

              if [ ! -d "$APP" ]; then
                echo "ERROR: Build succeeded but app was not found:" >&2
                echo "  $APP" >&2
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

              ${checkXcode}
              ${derivedDataSetup}

              echo "Generating Xcode project..."
              xcodegen generate

              echo
              echo "Building ${appName} (Release)..."

              /usr/bin/xcrun xcodebuild \
                -project "${projectFile}" \
                -scheme "${scheme}" \
                -configuration Release \
                -derivedDataPath "$DERIVED_DATA" \
                build

              APP="$DERIVED_DATA/Build/Products/Release/${appName}.app"

              if [ ! -d "$APP" ]; then
                echo "ERROR: Build succeeded but app was not found:" >&2
                echo "  $APP" >&2
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

              ${checkXcode}
              ${derivedDataSetup}

              echo "Generating Xcode project..."
              xcodegen generate

              echo
              echo "Building ${appName} (Release)..."

              /usr/bin/xcrun xcodebuild \
                -project "${projectFile}" \
                -scheme "${scheme}" \
                -configuration Release \
                -derivedDataPath "$DERIVED_DATA" \
                build

              APP="$DERIVED_DATA/Build/Products/Release/${appName}.app"
              INSTALL_DIR="$HOME/Applications"
              DEST="$INSTALL_DIR/${appName}.app"

              if [ ! -d "$APP" ]; then
                echo "ERROR: Build succeeded but app was not found:" >&2
                echo "  $APP" >&2
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

          dmgScript = pkgs.writeShellApplication {
            name = "package-${appName}-dmg";

            runtimeInputs = commonRuntimeInputs;

            text = ''
              set -euo pipefail

              ${checkXcode}
              ${derivedDataSetup}

              if [ ! -x /usr/sbin/diskutil ]; then
                echo "ERROR: diskutil was not found at /usr/sbin/diskutil." >&2
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
                -derivedDataPath "$DERIVED_DATA" \
                build

              APP="$DERIVED_DATA/Build/Products/Release/${appName}.app"
              INFO_PLIST="$APP/Contents/Info.plist"

              if [ ! -d "$APP" ]; then
                echo "ERROR: Build succeeded but app was not found:" >&2
                echo "  $APP" >&2
                exit 1
              fi

              if [ ! -f "$INFO_PLIST" ]; then
                echo "ERROR: Built app Info.plist was not found:" >&2
                echo "  $INFO_PLIST" >&2
                exit 1
              fi

              if ! VERSION=$(
                /usr/libexec/PlistBuddy \
                  -c "Print :CFBundleShortVersionString" \
                  "$INFO_PLIST" \
                  2>/dev/null
              ); then
                echo "ERROR: CFBundleShortVersionString could not be read from:" >&2
                echo "  $INFO_PLIST" >&2
                exit 1
              fi

              if [ -z "$VERSION" ]; then
                echo "ERROR: CFBundleShortVersionString is empty in:" >&2
                echo "  $INFO_PLIST" >&2
                exit 1
              fi

              DIST_DIR="$PWD/dist"
              /bin/mkdir -p "$DIST_DIR"

              STAGING_DIR=""

              cleanup() {
                if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
                  /bin/rm -rf "$STAGING_DIR"
                fi
              }

              trap cleanup EXIT

              STAGING_DIR=$(
                /usr/bin/mktemp -d "$DIST_DIR/.dmg-staging.XXXXXX"
              )

              /usr/bin/ditto \
                --rsrc \
                "$APP" \
                "$STAGING_DIR/${appName}.app"

              /bin/ln \
                -s \
                /Applications \
                "$STAGING_DIR/Applications"

              DMG="$DIST_DIR/${appName}-$VERSION.dmg"

              if [ -e "$DMG" ] || [ -L "$DMG" ]; then
                echo "Replacing existing DMG:"
                echo "  $DMG"

                /bin/rm -rf "$DMG"
              fi

              echo
              echo "Creating compressed read-only DMG..."

              /usr/sbin/diskutil image create from \
                --format UDZO \
                --volumeName "${appName}" \
                "$STAGING_DIR" \
                "$DMG"

              if [ ! -f "$DMG" ]; then
                echo "ERROR: DMG creation completed but final image was not found:" >&2
                echo "  $DMG" >&2
                exit 1
              fi

              echo
              echo "DMG information:"
              /usr/sbin/diskutil image info "$DMG"

              echo
              echo "Release DMG:"
              echo "  $DMG"

              echo
              echo "SHA-256:"
              /usr/bin/shasum -a 256 "$DMG"
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

          dmg = {
            type = "app";
            program = "${dmgScript}/bin/package-${appName}-dmg";
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
