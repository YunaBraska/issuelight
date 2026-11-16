#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
output_directory="$repository_root/docs/site/assets/screenshots"
temporary_root=${TMPDIR:-/tmp}
derived_data=$(mktemp -d "$temporary_root/issuelight-site-screenshots.XXXXXX")

cleanup() {
    rm -rf -- "$derived_data"
}
trap cleanup EXIT HUP INT TERM

xcodebuild build-for-testing \
    -quiet \
    -project "$repository_root/IssueLight/IssueLight.xcodeproj" \
    -scheme IssueLight \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO

test_bundle="$derived_data/Build/Products/Debug/IssueLightModelTests.xctest"
ditto \
    "$derived_data/Build/Products/Debug/Sparkle.framework" \
    "$derived_data/Build/Products/Debug/PackageFrameworks/Sparkle.framework"
ISSUELIGHT_SCREENSHOT_OUTPUT_DIR="$output_directory" \
    xcrun xctest \
    -XCTest IssueLightModelTests.LandingPageScreenshotTests/testLandingPageScreenshotsRenderFromProductionViews \
    "$test_bundle"

test -s "$output_directory/source-setup.png"
test -s "$output_directory/source-setup-thruk.png"
test -s "$output_directory/menu-item-states.png"
test -s "$output_directory/menu-panel-de.png"
test -s "$output_directory/menu-panel-sv.png"
test -s "$output_directory/menu-panel-ar.png"
test -s "$output_directory/menu-panel-source-failure.png"
test -s "$output_directory/menu-panel-all-providers.png"
test -s "$output_directory/language-settings-sv.png"
test -s "$output_directory/language-settings-ar.png"
test -s "$output_directory/settings-about.png"
test -s "$output_directory/settings-notifications.png"

printf '%s\n' "Generated IssueLight site screenshots in $output_directory"
