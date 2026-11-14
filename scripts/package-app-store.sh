#!/bin/sh

set -eu

test "$#" -eq 2 || {
    printf '%s\n' 'Expected marketing version and build number.' >&2
    exit 64
}

version=$1
build_number=$2
repository_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
dist_directory=${ISSUELIGHT_APP_STORE_DIST_DIRECTORY:-"${repository_root}/dist/app-store"}
temporary_directory=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/issuelight-app-store.XXXXXX")
allow_unsigned=${ISSUELIGHT_APP_STORE_ALLOW_UNSIGNED:-false}

case "$version" in
    ''|*[!0-9A-Za-z._-]*) printf '%s\n' 'Invalid marketing version.' >&2; exit 65 ;;
esac
case "$build_number" in
    ''|*[!0-9]*|0) printf '%s\n' 'Invalid App Store build number.' >&2; exit 65 ;;
esac
case "$allow_unsigned" in
    true|false) ;;
    *) printf '%s\n' 'ISSUELIGHT_APP_STORE_ALLOW_UNSIGNED must be true or false.' >&2; exit 65 ;;
esac

cleanup() {
    rm -rf "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

if [ "$allow_unsigned" = true ]; then
    app_store_team_id=0000000000
    app_store_bundle_id=berlin.yuna.issuelight
    signing_identity=-
    profile_name=
    profile_path=
else
    : "${APP_STORE_BUNDLE_ID:?APP_STORE_BUNDLE_ID is required}"
    : "${APP_STORE_TEAM_ID:?APP_STORE_TEAM_ID is required}"
    : "${MACOS_APP_STORE_APPLICATION_IDENTITY:?MACOS_APP_STORE_APPLICATION_IDENTITY is required}"
    : "${MACOS_APP_STORE_PROFILE_NAME:?MACOS_APP_STORE_PROFILE_NAME is required}"
    : "${MACOS_APP_STORE_PROFILE_PATH:?MACOS_APP_STORE_PROFILE_PATH is required}"
    app_store_team_id=$APP_STORE_TEAM_ID
    app_store_bundle_id=$APP_STORE_BUNDLE_ID
    signing_identity=$MACOS_APP_STORE_APPLICATION_IDENTITY
    profile_name=$MACOS_APP_STORE_PROFILE_NAME
    profile_path=$MACOS_APP_STORE_PROFILE_PATH
fi

case "$app_store_team_id" in
    [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;;
    *) printf '%s\n' 'Invalid App Store team identifier.' >&2; exit 65 ;;
esac

entitlements="$temporary_directory/IssueLight-AppStore.entitlements"
cp "$repository_root/IssueLight/Resources/IssueLight-AppStore.entitlements" "$entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string ${app_store_team_id}.${app_store_bundle_id}" "$entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string ${app_store_team_id}" "$entitlements"
/usr/libexec/PlistBuddy -c 'Add :keychain-access-groups array' "$entitlements"
/usr/libexec/PlistBuddy -c "Add :keychain-access-groups:0 string ${app_store_team_id}.${app_store_bundle_id}" "$entitlements"

derived_data="$temporary_directory/DerivedData"
if [ "$allow_unsigned" = true ]; then
    xcodebuild build \
        -project "$repository_root/IssueLight/IssueLight.xcodeproj" \
        -scheme IssueLight \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$derived_data" \
        ARCHS='arm64 x86_64' \
        ONLY_ACTIVE_ARCH=NO \
        MARKETING_VERSION="$version" \
        CURRENT_PROJECT_VERSION="$build_number" \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) ISSUELIGHT_APP_STORE' \
        CODE_SIGNING_ALLOWED=NO
else
    xcodebuild build \
        -project "$repository_root/IssueLight/IssueLight.xcodeproj" \
        -scheme IssueLight \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$derived_data" \
        ARCHS='arm64 x86_64' \
        ONLY_ACTIVE_ARCH=NO \
        MARKETING_VERSION="$version" \
        CURRENT_PROJECT_VERSION="$build_number" \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) ISSUELIGHT_APP_STORE' \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$signing_identity" \
        DEVELOPMENT_TEAM="$app_store_team_id" \
        PROVISIONING_PROFILE_SPECIFIER="$profile_name" \
        CODE_SIGN_ENTITLEMENTS="$entitlements"
fi

app="$derived_data/Build/Products/Release/IssueLight.app"
test -d "$app" || {
    printf '%s\n' 'App Store build did not create IssueLight.app.' >&2
    exit 66
}

if [ "$allow_unsigned" = false ]; then
    cp "$profile_path" "$app/Contents/embedded.provisionprofile"
fi
codesign --force --sign "$signing_identity" --entitlements "$entitlements" --options runtime --timestamp "$app"
codesign --verify --deep --strict --verbose=2 "$app"

app_entitlements=$(codesign -d --entitlements :- "$app" 2>/dev/null)
printf '%s\n' "$app_entitlements" | plutil -extract 'com\.apple\.security\.app-sandbox' raw - | grep -Fx true >/dev/null
printf '%s\n' "$app_entitlements" | plutil -extract 'com\.apple\.security\.network\.client' raw - | grep -Fx true >/dev/null
if printf '%s\n' "$app_entitlements" | plutil -extract 'com\.apple\.security\.network\.server' raw - >/dev/null 2>&1; then
    printf '%s\n' 'App Store app must not request incoming network connections.' >&2
    exit 65
fi
if strings "$app/Contents/MacOS/IssueLight" | grep -F '/usr/bin/ssh' >/dev/null \
    || strings "$app/Contents/MacOS/IssueLight" | grep -F '/usr/bin/nc' >/dev/null; then
    printf '%s\n' 'App Store app must not contain external tunnel executables.' >&2
    exit 65
fi

rm -rf "$dist_directory"
mkdir -p "$dist_directory"
ditto "$app" "$dist_directory/IssueLight.app"
