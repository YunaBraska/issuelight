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
set --
if [ "${GITHUB_ACTIONS:-}" = true ]; then
    # Hosted macOS runners have no interactive WindowServer for pointer events.
    set -- -skip-testing:IssueLightModelTests/StatusMenuInteractionTests
fi
xcodebuild test \
    -project IssueLight/IssueLight.xcodeproj \
    -scheme IssueLight \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    "$@" \
    CODE_SIGNING_ALLOWED=NO

release_version=$(xcodebuild \
    -project IssueLight/IssueLight.xcodeproj \
    -scheme IssueLight \
    -configuration Release \
    -showBuildSettings \
    | awk '/^[[:space:]]*MARKETING_VERSION = / { print $3; exit }')
test -n "$release_version"
update_private_key=$(openssl rand -base64 32)
update_key_der="$check_work_directory/update-key.der"
{
    printf '\060\056\002\001\000\060\005\006\003\053\145\160\004\042\004\040'
    printf '%s' "$update_private_key" | base64 -D
} > "$update_key_der"
update_public_key=$(openssl pkey \
    -inform DER \
    -in "$update_key_der" \
    -pubout \
    -outform DER \
    | tail -c 32 \
    | base64)
case "$update_public_key" in
    A*) mismatched_update_public_key="B${update_public_key#?}" ;;
    *) mismatched_update_public_key="A${update_public_key#?}" ;;
esac
if ISSUELIGHT_DIST_DIRECTORY="$check_work_directory/MismatchedUpdateKeys" \
    MACOS_UPDATE_PRIVATE_KEY="$update_private_key" \
    MACOS_UPDATE_PUBLIC_KEY="$mismatched_update_public_key" \
    scripts/package.sh "$release_version" >/dev/null 2>&1; then
    echo "Packaging accepted a mismatched Sparkle update-key pair." >&2
    exit 1
fi
ISSUELIGHT_DIST_DIRECTORY="$check_work_directory/Release" \
MACOS_UPDATE_PRIVATE_KEY="$update_private_key" \
MACOS_UPDATE_PUBLIC_KEY="$update_public_key" \
    scripts/package.sh "$release_version"

archive_path="$check_work_directory/Release/IssueLight-$release_version-macos-universal-UNSIGNED.zip"
dmg_path="$check_work_directory/Release/IssueLight-$release_version-macos-universal-UNSIGNED.dmg"
test -f "$archive_path"
test -f "$dmg_path"
test -f "$check_work_directory/Release/appcast.xml"
grep -F "IssueLight-$release_version-macos-universal-UNSIGNED.dmg" \
    "$check_work_directory/Release/appcast.xml" >/dev/null
(
    cd "$check_work_directory/Release"
    shasum -a 256 -c SHA256SUMS
)
extracted_directory="$check_work_directory/Extracted"
mkdir "$extracted_directory"
ditto -x -k "$archive_path" "$extracted_directory"
app_path="$extracted_directory/IssueLight.app"
test -d "$app_path"
test -d "$app_path/Contents/Frameworks/Sparkle.framework"
test -f "$app_path/Contents/Resources/Sparkle-LICENSE.txt"
test "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app_path/Contents/Info.plist")" = \
    "https://github.com/YunaBraska/issuelight/releases/latest/download/appcast.xml"
test "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app_path/Contents/Info.plist")" = \
    "$update_public_key"
test "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$app_path/Contents/Info.plist")" = true
test "$(/usr/libexec/PlistBuddy -c 'Print :SUAutomaticallyUpdate' "$app_path/Contents/Info.plist")" = false
test "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$app_path/Contents/Info.plist")" = true
test "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$app_path/Contents/Info.plist")" = true

release_build=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' \
    "$app_path/Contents/Info.plist")
sbom_path="$check_work_directory/Release/IssueLight-$release_version-UNSIGNED.spdx.json"
test "$(plutil -extract spdxVersion raw "$sbom_path")" = "SPDX-2.3"
test "$(plutil -extract packages.0.versionInfo raw "$sbom_path")" = \
    "$release_version ($release_build)"
test "$(plutil -extract packages.1.name raw "$sbom_path")" = "Sparkle"
test "$(plutil -extract packages.1.versionInfo raw "$sbom_path")" = "2.10.0"
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

ISSUELIGHT_APP_STORE_ALLOW_UNSIGNED=true \
ISSUELIGHT_APP_STORE_DIST_DIRECTORY="$check_work_directory/AppStore" \
sh scripts/package-app-store.sh "$release_version" 1
store_app="$check_work_directory/AppStore/IssueLight.app"
test -d "$store_app"
test ! -d "$store_app/Contents/Frameworks/Sparkle.framework"
test ! -e "$store_app/Contents/Resources/Sparkle-LICENSE.txt"
if /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$store_app/Contents/Info.plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$store_app/Contents/Info.plist" >/dev/null 2>&1; then
    echo "App Store package contains direct-release update configuration." >&2
    exit 1
fi
codesign --verify --deep --strict "$store_app"
store_entitlements=$(codesign -d --entitlements :- "$store_app" 2>/dev/null)
printf '%s\n' "$store_entitlements" | plutil -extract 'com\.apple\.security\.app-sandbox' raw - | grep -Fx true >/dev/null
printf '%s\n' "$store_entitlements" | plutil -extract 'com\.apple\.security\.network\.client' raw - | grep -Fx true >/dev/null
if printf '%s\n' "$store_entitlements" | plutil -extract 'com\.apple\.security\.network\.server' raw - >/dev/null 2>&1; then
    echo "App Store package requested an incoming-network entitlement." >&2
    exit 1
fi

if git ls-files | grep -E '(^|/)(\.env\.local|[^/]+\.(p12|pfx|key))$' >/dev/null; then
    echo "A tracked file can contain release credentials." >&2
    exit 1
fi

git diff --check
