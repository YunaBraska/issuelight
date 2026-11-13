#!/bin/sh

set -eu

script_directory=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
repository_root=$(CDPATH='' cd "$script_directory/.." && pwd -P)
check_temp_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
check_temp_root=${check_temp_root%/}
test -n "$check_temp_root" || check_temp_root=/tmp
test "$check_temp_root" != / || {
    echo "The check temporary directory must not be the filesystem root." >&2
    exit 65
}
mkdir -p "$check_temp_root"
check_work_directory=$(mktemp -d "$check_temp_root/issuelight-check.XXXXXX")
cleanup() {
    case "$check_work_directory" in
        "$check_temp_root"/issuelight-check.*) rm -rf "$check_work_directory" ;;
        *) echo "Refusing to clean unexpected check directory." >&2 ;;
    esac
}
trap cleanup EXIT HUP INT TERM

cd "$repository_root"

for script in scripts/*.sh; do
    sh -n "$script"
done

swift test --package-path Packages/IssueLightCore --enable-code-coverage
coverage_path=$(swift test \
    --package-path Packages/IssueLightCore \
    --show-codecov-path)
coverage_profile="$(dirname "$coverage_path")/default.profdata"
test_binary=$(find Packages/IssueLightCore/.build -type f \
    -path '*/IssueLightCore*Tests.xctest/Contents/MacOS/IssueLightCore*Tests' \
    -print -quit)
test -n "$test_binary"
coverage_json="$check_work_directory/IssueLightCoreCoverage.json"
xcrun llvm-cov export \
    "$test_binary" \
    -instr-profile="$coverage_profile" \
    -ignore-filename-regex='Tests/|\.build/' \
    -summary-only > "$coverage_json"
scripts/check_coverage.sh "$coverage_json" 86.0 79.0
if scripts/check_coverage.sh "$coverage_json" 100 100 >/dev/null 2>&1; then
    echo "Coverage ratchet accepted an impossible threshold." >&2
    exit 1
fi

derived_data_path="$check_work_directory/DerivedData"
xcodebuild test \
    -project IssueLight/IssueLight.xcodeproj \
    -scheme IssueLight \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO

release_version=$(xcodebuild \
    -project IssueLight/IssueLight.xcodeproj \
    -scheme IssueLight \
    -configuration Release \
    -showBuildSettings \
    | awk '/^[[:space:]]*MARKETING_VERSION = / { print $3; exit }')
test -n "$release_version"
ISSUELIGHT_DIST_DIRECTORY="$check_work_directory/Release" \
    scripts/package.sh "$release_version"

archive_path="$check_work_directory/Release/IssueLight-$release_version-macos-universal-UNSIGNED.zip"
dmg_path="$check_work_directory/Release/IssueLight-$release_version-macos-universal-UNSIGNED.dmg"
test -f "$archive_path"
test -f "$dmg_path"
(
    cd "$check_work_directory/Release"
    shasum -a 256 -c SHA256SUMS
)
extracted_directory="$check_work_directory/Extracted"
mkdir "$extracted_directory"
ditto -x -k "$archive_path" "$extracted_directory"
app_path="$extracted_directory/IssueLight.app"
test -d "$app_path"

release_build=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' \
    "$app_path/Contents/Info.plist")
sbom_path="$check_work_directory/Release/IssueLight-$release_version-UNSIGNED.spdx.json"
test "$(plutil -extract spdxVersion raw "$sbom_path")" = "SPDX-2.3"
test "$(plutil -extract packages.0.versionInfo raw "$sbom_path")" = \
    "$release_version ($release_build)"
if scripts/package_release.sh \
    "$app_path" \
    "$check_work_directory/Release" \
    "$release_version" \
    "$(git rev-parse HEAD)" \
    --allow-unsigned; then
    echo "Packaging overwrote existing artifacts." >&2
    exit 1
fi
if scripts/package_release.sh \
    "$app_path" \
    "$check_work_directory/SignedNegative" \
    "$release_version" \
    "$(git rev-parse HEAD)"; then
    echo "Unsigned app passed signed release verification." >&2
    exit 1
fi
if scripts/package_release.sh \
    "$app_path" \
    "$check_work_directory/VersionNegative" \
    "$release_version.invalid" \
    "$(git rev-parse HEAD)" \
    --allow-unsigned; then
    echo "Packaging accepted a mismatched version." >&2
    exit 1
fi

if git ls-files | grep -E '(^|/)(\.env\.local|[^/]+\.(p12|pfx|key))$' >/dev/null; then
    echo "A tracked file can contain release credentials." >&2
    exit 1
fi

git diff --check
