#!/bin/bash
# Builds, tests and uploads Ramble with the settings it needs. Run scripts/build.sh for the list.
set -euo pipefail
cd "$(dirname "$0")/.."

derived=build/DerivedData
archive=build/Ramble.xcarchive

# -skipMacroValidation, -skipPackagePluginValidation: the packages' macros and plugins would otherwise
#   wait for someone to approve them in Xcode, which a command line can't do.
# -IDEPackageEnablePrebuilts=NO: the prebuilt swift-syntax is made for one compiler version, and the
#   macros stop building when Xcode moves on. Built from source, it works with any version.
# -onlyUsePackageVersionsFromResolvedFile: the versions in Package.resolved, nothing newer.
settings=(-project Ramble.xcodeproj -scheme Ramble -derivedDataPath "$derived"
          -skipMacroValidation -skipPackagePluginValidation
          -onlyUsePackageVersionsFromResolvedFile -IDEPackageEnablePrebuilts=NO)

usage() {
    cat <<'EOF'
Usage: scripts/build.sh <command> [app launch arguments]

  sim       Debug build, then install and open it on a simulator; anything after it goes to
            the app, like: scripts/build.sh sim -sampleData -startTab ledger
  phone     Release build, then install it on a connected iPhone without opening it
  test      Unit tests
  uitest    Interface tests: launch, capture, reminder tap, photo, by category, 问一问
  archive   Release archive at build/Ramble.xcarchive
  upload    Archive, then send it to App Store Connect (bump the version first)
  doctor    Check Xcode and the Metal Toolchain

Environment:
  RAMBLE_SIMULATOR  a simulator's name or UDID (default: the booted iPhone, else the first one)
  RAMBLE_DEVICE     an iPhone's name or identifier (default: the only one connected)
EOF
}

# The simulator to use, as a UDID.
simulator() {
    if [ -n "${RAMBLE_SIMULATOR:-}" ]; then
        xcrun simctl list devices available | grep -F "$RAMBLE_SIMULATOR" | head -1 | grep -oE '[0-9A-F-]{36}' && return
        echo "No simulator matches RAMBLE_SIMULATOR=$RAMBLE_SIMULATOR" >&2
        exit 1
    fi
    local list
    list=$(xcrun simctl list devices available | grep -E '^ +iPhone' || true)
    { echo "$list" | grep -F '(Booted)' || echo "$list"; } | head -1 | grep -oE '[0-9A-F-]{36}' && return
    echo "No iPhone simulator found. Add a runtime in Xcode › Settings › Components." >&2
    exit 1
}

boot() {
    xcrun simctl boot "$1" 2>/dev/null || true
    xcrun simctl bootstatus "$1" -b >/dev/null
}

# MLX compiles Metal shaders, and Xcode updates can leave this optional component behind.
check_metal() {
    xcrun metal --version >/dev/null 2>&1 && return
    echo "The Metal Toolchain is missing, and the build needs it (it can be close to 1 GB)." >&2
    if [ -t 0 ]; then
        read -r -p "Download it from Apple now? [y/N] " answer
        if [ "$answer" = y ] || [ "$answer" = Y ]; then
            xcodebuild -downloadComponent MetalToolchain
            return
        fi
    fi
    echo "Run: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
}

# After an Xcode update, leftovers from the old compiler fail the build with "Unable to resolve Swift
# module dependency". They're only caches, so they go, once per Xcode version.
clear_old_caches() {
    local version stamp=build/.xcode-version
    version=$(xcodebuild -version | tr '\n' ' ')
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" != "$version" ]; then
        echo "Xcode changed: clearing what the old version left in $derived"
        rm -rf "$derived/SourcePackages/prebuilts" "$derived/Build/Intermediates.noindex/XCBuildData/PIFCache"
    fi
    mkdir -p build
    echo "$version" >"$stamp"
}

prepare() {
    check_metal
    clear_old_caches
}

# Keeps the build's output down to the errors and the result; the rest goes to a log.
quiet() {
    local log=build/last-build.log
    mkdir -p build
    if "$@" >"$log" 2>&1; then
        grep -E '^\*\* .* \*\*|Test run with|Executed [1-9][0-9]* tests' "$log" | awk '!seen[$0]++' || true
    else
        grep -E 'error:|✘|failed|^\*\* .* \*\*' "$log" | head -40 >&2 || true
        echo "The full log is in $log" >&2
        exit 1
    fi
}

command=${1:-}
[ $# -gt 0 ] && shift

case "$command" in
sim)
    prepare
    udid=$(simulator)
    quiet xcodebuild "${settings[@]}" -configuration Debug -destination "id=$udid" build
    boot "$udid"
    xcrun simctl install "$udid" "$derived/Build/Products/Debug-iphonesimulator/Ramble.app"
    xcrun simctl terminate "$udid" com.zengji.suikouji 2>/dev/null || true
    xcrun simctl launch "$udid" com.zengji.suikouji "$@"
    ;;
phone)
    prepare
    quiet xcodebuild "${settings[@]}" -configuration Release -destination 'generic/platform=iOS' -allowProvisioningUpdates build
    device=${RAMBLE_DEVICE:-}
    if [ -z "$device" ]; then
        phones=$(xcrun devicectl list devices 2>/dev/null | grep 'iPhone' | grep -v 'simulated' || true)
        if [ "$(printf '%s' "$phones" | grep -c .)" != 1 ]; then
            echo "Couldn't tell which iPhone to use. Set RAMBLE_DEVICE; xcrun devicectl list devices shows them." >&2
            exit 1
        fi
        device=$(echo "$phones" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f-]+' | head -1)
    fi
    # "The device disconnected" or a disk image error: unlock the phone, or plug it in once, and retry.
    xcrun devicectl device install app --device "$device" "$derived/Build/Products/Release-iphoneos/Ramble.app"
    ;;
test | uitest)
    prepare
    udid=$(simulator)
    quiet xcodebuild "${settings[@]}" -configuration Debug -destination "id=$udid" build-for-testing
    if [ "$command" = test ]; then
        target=RambleTests
    else
        target=RambleUITests
    fi
    # One at a time: the interface tests share the simulator, and the unit tests are written for
    # Simplified Chinese because that's the language they parse.
    quiet xcodebuild "${settings[@]}" -configuration Debug -destination "id=$udid" test-without-building \
        -only-testing:"$target" -parallel-testing-enabled NO -testLanguage zh-Hans -testRegion zh_CN
    ;;
archive | upload)
    prepare
    quiet xcodebuild "${settings[@]}" -configuration Release -destination 'generic/platform=iOS' \
        -archivePath "$archive" -allowProvisioningUpdates archive
    python3 scripts/check_intent_text.py "$archive"
    echo "Archived: $archive"
    if [ "$command" = upload ]; then
        quiet xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist scripts/ExportOptions.plist \
            -exportPath build/export -allowProvisioningUpdates
        echo "Sent to App Store Connect. It shows up there after Apple has processed it."
    fi
    ;;
doctor)
    xcodebuild -version
    if xcrun metal --version >/dev/null 2>&1; then
        echo "Metal Toolchain: installed"
    else
        echo "Metal Toolchain: missing. Run: xcodebuild -downloadComponent MetalToolchain"
    fi
    echo "Simulator: $(simulator)"
    ;;
*)
    usage
    [ -z "$command" ] || exit 1
    ;;
esac
