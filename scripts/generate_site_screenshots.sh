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
ISSUELIGHT_SCREENSHOT_OUTPUT_DIR="$output_directory" \
    xcrun xctest \
    -XCTest IssueLightModelTests.LandingPageScreenshotTests/testLandingPageScreenshotsRenderFromProductionViews \
    "$test_bundle"

test -s "$output_directory/attention-overview.png"
test -s "$output_directory/source-setup.png"

printf '%s\n' "Generated IssueLight site screenshots in $output_directory"
