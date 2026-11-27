#!/bin/sh
# Opt-in native Simulator test for LegacyTraitLayout.mm.
# --build-only compiles and signs the test apps without installing or launching.
# --baseline also verifies that an unpatched SDK 4.2 app reproduces the extra
# layoutSubviews on trait invalidation.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
device=booted
build_only=0
baseline=0
keep=0
run_timeout=${LC32_TRAIT_LAYOUT_TIMEOUT:-30}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --device) device=$2; shift 2 ;;
        --build-only) build_only=1; keep=1; shift ;;
        --baseline) baseline=1; shift ;;
        --keep) keep=1; shift ;;
        *) echo "usage: $0 [--device UDID] [--build-only] [--baseline] [--keep]" >&2; exit 2 ;;
    esac
done
case "$run_timeout" in ''|*[!0-9]*) echo "invalid timeout" >&2; exit 2 ;; esac
[ "$run_timeout" -ge 1 ] && [ "$run_timeout" -le 60 ] || exit 2

temp_base=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
workdir=$(mktemp -d "$temp_base/lc32-trait-layout.XXXXXX")
run_id=$(basename "$workdir" | tr -cd '[:alnum:]')
installed_bundle=

bounded() {
    perl -e 'alarm shift; exec @ARGV; die "exec: $!\n"' "$@"
}
cleanup() {
    result=$?
    trap - EXIT INT TERM
    if [ -n "$installed_bundle" ]; then
        bounded 10 xcrun simctl terminate "$device" "$installed_bundle" >/dev/null 2>&1 || :
        bounded 10 xcrun simctl uninstall "$device" "$installed_bundle" >/dev/null 2>&1 || :
    fi
    if [ "$keep" -eq 1 ] || [ "$result" -ne 0 ]; then
        echo "Trait layout artifacts: $workdir"
    else
        case "$workdir" in "$temp_base"/lc32-trait-layout.*) rm -rf -- "$workdir" ;; esac
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sdk_root=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator clang++ -target arm64-apple-ios15.0-simulator \
    -std=c++17 -isysroot "$sdk_root" -fobjc-arc -g -O2 -Wall -Wextra -Werror \
    -c "$repo_root/HostFrameworks/UIKit/LegacyTraitLayout.mm" \
    -o "$workdir/LegacyTraitLayout.o"
compile() {
    output=$1
    shift
    xcrun --sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator \
        -isysroot "$sdk_root" -fobjc-arc -g -O2 -Wall -Wextra -Werror \
        -Wl,-headerpad,0x1000 -framework UIKit -framework QuartzCore \
        -framework CoreGraphics -framework Foundation -lc++ "$repo_root/test/uikit_legacy_trait_layout.m" \
        "$@" -o "$output"
}
compile "$workdir/fixed" "$workdir/LegacyTraitLayout.o"
if [ "$baseline" -eq 1 ]; then compile "$workdir/unpatched"; fi

run_case() {
    variant=$1
    process_sdk=$2
    guest_sdk=$3
    has_fix=$4
    expect_suppress=$5
    expect_gl_relayout=$6
    expect_legacy_subtree=$7
    set_root_vc=$8
    expect_prelayout_cb=$9
    binary=${10}

    app="$workdir/$variant.app"
    bundle="org.liveexec32.test.traitlayout.$run_id.$variant"
    mkdir "$app"
    plist="$app/Info.plist"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleExecutable -string TraitLayout "$plist"
    plutil -insert CFBundleIdentifier -string "$bundle" "$plist"
    plutil -insert CFBundleName -string "$variant" "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleVersion -string 1 "$plist"
    plutil -insert CFBundleShortVersionString -string 1.0 "$plist"
    plutil -insert MinimumOSVersion -string 15.0 "$plist"
    plutil -insert LSRequiresIPhoneOS -bool YES "$plist"
    plutil -insert UIDeviceFamily -json '[1,2]' "$plist"
    plutil -insert CFBundleSupportedPlatforms -json '["iPhoneSimulator"]' "$plist"
    plutil -insert LC32GuestSDK -integer "$guest_sdk" "$plist"
    plutil -insert LC32HasFix -bool "$has_fix" "$plist"
    plutil -insert LC32ExpectSuppress -bool "$expect_suppress" "$plist"
    plutil -insert LC32ExpectGLRelayout -bool "$expect_gl_relayout" "$plist"
    plutil -insert LC32ExpectLegacySubtreeInvalidation -bool "$expect_legacy_subtree" "$plist"
    plutil -insert LC32SetRootViewController -bool "$set_root_vc" "$plist"
    plutil -insert LC32ExpectPreLayoutCallback -bool "$expect_prelayout_cb" "$plist"

    xcrun vtool -set-build-version 7 15.0 "$process_sdk" -replace \
        -output "$app/TraitLayout" "$binary"
    codesign --force --sign - "$app" >/dev/null 2>&1
    codesign --verify --strict "$app"
    echo "Built $app ($bundle), processSDK=$process_sdk guestSDK=$guest_sdk fix=$has_fix"
    [ "$build_only" -eq 0 ] || return 0

    installed_bundle=$bundle
    bounded "$run_timeout" xcrun simctl install "$device" "$app"
    status=0
    bounded "$run_timeout" xcrun simctl launch --console "$device" "$bundle" \
        >"$workdir/$variant.log" 2>&1 || status=$?
    echo "Trait layout launch status ($variant): $status"
    sed -n '1,120p' "$workdir/$variant.log"
    bounded 10 xcrun simctl terminate "$device" "$bundle" >/dev/null 2>&1 || :
    bounded 10 xcrun simctl uninstall "$device" "$bundle"
    installed_bundle=
    [ "$status" -eq 0 ] && grep -q 'trait-layout-regression: PASS' "$workdir/$variant.log"
}

run_case sdk4-guest0 4.2 0 YES YES NO YES NO NO "$workdir/fixed"
run_case sdk7-guest7 7.0 458752 YES YES NO YES NO NO "$workdir/fixed"
run_case sdk11-guest0 11.0 0 YES YES NO NO YES NO "$workdir/fixed"
run_case sdk4-guest8 4.2 524288 YES NO YES YES NO NO "$workdir/fixed"
run_case sdk17-guest0 17.0 0 YES YES NO NO YES YES "$workdir/fixed"
if [ "$baseline" -eq 1 ]; then
    run_case sdk4-guest0-baseline 4.2 0 NO NO YES YES NO NO "$workdir/unpatched"
    run_case sdk11-guest0-baseline 11.0 0 NO NO YES NO YES NO "$workdir/unpatched"
    run_case sdk17-guest0-baseline 17.0 0 NO NO YES NO YES YES "$workdir/unpatched"
fi
