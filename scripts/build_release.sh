#!/bin/sh

set -eu

usage() {
    echo "Usage: $0 OUTPUT_DIRECTORY REVISION" >&2
    echo "Requires APPLE_TEAM_ID, APPLE_SIGNING_IDENTITY, and NOTARY_KEYCHAIN_PROFILE." >&2
    exit 64
}

test "$#" -eq 2 || usage

output_directory=$1
revision=$2

case "$output_directory" in
    /) echo "OUTPUT_DIRECTORY must not be the filesystem root." >&2; exit 65 ;;
    /*) ;;
    *) echo "OUTPUT_DIRECTORY must be absolute." >&2; exit 65 ;;
esac
case "$revision" in
    ''|*[!0-9a-f]*) echo "REVISION must be a lowercase hexadecimal Git revision." >&2; exit 65 ;;
esac
test "${#revision}" -ge 7 || { echo "REVISION is too short." >&2; exit 65; }
test "${#revision}" -le 64 || { echo "REVISION is too long." >&2; exit 65; }

test -n "${APPLE_TEAM_ID:-}" || {
    echo "APPLE_TEAM_ID is required." >&2
    exit 65
}
case "$APPLE_TEAM_ID" in
    *[!A-Z0-9]*|'') echo "APPLE_TEAM_ID must contain only uppercase letters and numbers." >&2; exit 65 ;;
esac
test "${#APPLE_TEAM_ID}" -eq 10 || {
    echo "APPLE_TEAM_ID must contain exactly 10 characters." >&2
    exit 65
}
test -n "${APPLE_SIGNING_IDENTITY:-}" || {
    echo "APPLE_SIGNING_IDENTITY is required." >&2
    exit 65
}
case "$APPLE_SIGNING_IDENTITY" in
    Developer\ ID\ Application:*) ;;
    *) echo "APPLE_SIGNING_IDENTITY must name a Developer ID Application identity." >&2; exit 65 ;;
esac
test -n "${NOTARY_KEYCHAIN_PROFILE:-}" || {
    echo "NOTARY_KEYCHAIN_PROFILE is required." >&2
    exit 65
}

script_directory=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
repository_root=$(CDPATH='' cd "$script_directory/.." && pwd -P)
head_revision=$(git -C "$repository_root" rev-parse HEAD)
test "$revision" = "$head_revision" || {
    echo "REVISION does not match the checked-out commit." >&2
    exit 65
}
test -z "$(git -C "$repository_root" status --porcelain --untracked-files=all)" || {
    echo "Release builds require a clean working tree." >&2
    exit 65
}

release_temp_root=${TMPDIR:-/tmp}
release_temp_root=${release_temp_root%/}
test -n "$release_temp_root" || release_temp_root=/
test "$release_temp_root" != / || {
    echo "TMPDIR must not be the filesystem root." >&2
    exit 65
}
test -d "$release_temp_root" || {
    echo "TMPDIR does not exist: $release_temp_root" >&2
    exit 66
}
release_work_directory=$(mktemp -d "$release_temp_root/issuelight-release.XXXXXX")
cleanup() {
    case "$release_work_directory" in
        "$release_temp_root"/issuelight-release.*) rm -rf "$release_work_directory" ;;
        *) echo "Refusing to clean unexpected release work directory." >&2 ;;
    esac
}
trap cleanup EXIT HUP INT TERM

derived_data_path="$release_work_directory/DerivedData"
xcodebuild build \
    -project "$repository_root/IssueLight/IssueLight.xcodeproj" \
    -scheme IssueLight \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_STYLE=Manual \
    "CODE_SIGN_IDENTITY=$APPLE_SIGNING_IDENTITY" \
    "DEVELOPMENT_TEAM=$APPLE_TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS='--timestamp'

app_path="$derived_data_path/Build/Products/Release/IssueLight.app"
info_plist="$app_path/Contents/Info.plist"
test -d "$app_path" || { echo "Release app was not built." >&2; exit 66; }
codesign --verify --deep --strict "$app_path"

signature_details=$(codesign -d --verbose=4 "$app_path" 2>&1)
printf '%s\n' "$signature_details" | grep -q '^Authority=Developer ID Application:' || {
    echo "Release app is not signed with Developer ID Application." >&2
    exit 65
}
printf '%s\n' "$signature_details" | grep -q 'flags=.*runtime' || {
    echo "Release app is missing hardened runtime." >&2
    exit 65
}
signed_team=$(printf '%s\n' "$signature_details" | sed -n 's/^TeamIdentifier=//p')
test "$signed_team" = "$APPLE_TEAM_ID" || {
    echo "Release app was signed by an unexpected Apple team." >&2
    exit 65
}
entitlements=$(codesign -d --entitlements :- "$app_path" 2>/dev/null)
if printf '%s\n' "$entitlements" \
    | plutil -extract 'com\.apple\.security\.get-task-allow' raw - 2>/dev/null \
    | grep -q '^true$'; then
    echo "Release app must not enable com.apple.security.get-task-allow." >&2
    exit 65
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
submission_archive="$release_work_directory/IssueLight-$version-notarization.zip"
submission_result="$release_work_directory/notary-submission.plist"
notary_log="$release_work_directory/notary-log.json"

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submission_archive"
unzip -tq "$submission_archive"
submission_exit=0
xcrun notarytool submit "$submission_archive" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait \
    --timeout 60m \
    --output-format plist \
    > "$submission_result" || submission_exit=$?
if ! submission_id=$(plutil -extract id raw "$submission_result" 2>/dev/null); then
    echo "Notarization submission failed before a result was accepted." >&2
    exit 69
fi

submission_status=$(plutil -extract status raw "$submission_result")
if ! xcrun notarytool log \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    "$submission_id" \
    "$notary_log"; then
    echo "Could not retrieve notarization log. Submission: $submission_id" >&2
    exit 69
fi
notary_issue_count=$(plutil -extract issues raw "$notary_log")
case "$notary_issue_count" in
    ''|*[!0-9]*) echo "Notarization log has an invalid issues list." >&2; exit 65 ;;
esac
if test "$submission_exit" -ne 0 \
    || test "$submission_status" != Accepted \
    || test "$notary_issue_count" -ne 0; then
    echo "Notarization did not finish cleanly. Submission: $submission_id" >&2
    plutil -p "$notary_log" >&2
    exit 65
fi

xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"

"$script_directory/package_release.sh" \
    "$app_path" \
    "$output_directory" \
    "$version" \
    "$revision"

echo "Notarization submission: $submission_id"
