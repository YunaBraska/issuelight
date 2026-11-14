#!/bin/sh

set -eu

usage() {
    echo "Usage: $0 VERSION" >&2
    exit 64
}

test "$#" -eq 1 || usage
version=$1
case "$version" in
    ''|*[!A-Za-z0-9._-]*) echo "VERSION contains unsupported characters." >&2; exit 65 ;;
esac
case "$version" in
    [A-Za-z0-9]*) ;;
    *) echo "VERSION must begin with a letter or number." >&2; exit 65 ;;
esac

script_directory=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
repository_root=$(CDPATH='' cd "$script_directory/.." && pwd -P)
identity=${MACOS_SIGNING_IDENTITY:--}
notary_profile=${MACOS_NOTARY_PROFILE:-}
build_number=${GITHUB_RUN_ID:-1}
signing_flags=
case "$build_number" in
    ''|*[!0-9]*|0) echo "The build number must be a positive integer." >&2; exit 65 ;;
esac
if test -n "$notary_profile" && test "$identity" = -; then
    echo "Notarization requires a Developer ID signing identity." >&2
    exit 65
fi
if test "$identity" != -; then
    test -n "$notary_profile" || {
        echo "A publishable Developer ID build requires notarization." >&2
        exit 65
    }
    signing_flags=--timestamp
fi

package_temp_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
package_temp_root=${package_temp_root%/}
test -n "$package_temp_root" || package_temp_root=/tmp
test "$package_temp_root" != / || {
    echo "The package temporary directory must not be the filesystem root." >&2
    exit 65
}
mkdir -p "$package_temp_root"
package_work_directory=$(mktemp -d "$package_temp_root/issuelight-package.XXXXXX")
cleanup() {
    case "$package_work_directory" in
        "$package_temp_root"/issuelight-package.*) rm -rf "$package_work_directory" ;;
        *) echo "Refusing to clean unexpected package directory." >&2 ;;
    esac
}
trap cleanup EXIT HUP INT TERM

derived_data_path="$package_work_directory/DerivedData"
cd "$repository_root"
xcodebuild build \
    -project IssueLight/IssueLight.xcodeproj \
    -scheme IssueLight \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$identity" \
    OTHER_CODE_SIGN_FLAGS="$signing_flags"

app_path="$derived_data_path/Build/Products/Release/IssueLight.app"
test -d "$app_path" || {
    echo "Release app was not built." >&2
    exit 66
}
codesign --verify --deep --strict "$app_path"

if test -n "$notary_profile"; then
    submission_archive="$package_work_directory/IssueLight-notarization.zip"
    submission_result="$package_work_directory/app-notary-result.plist"
    submission_log="$package_work_directory/app-notary-log.json"
    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submission_archive"
    submission_exit=0
    xcrun notarytool submit "$submission_archive" \
        --keychain-profile "$notary_profile" \
        --wait \
        --timeout 90m \
        --output-format plist > "$submission_result" || submission_exit=$?
    submission_id=$(plutil -extract id raw "$submission_result" 2>/dev/null) || {
        echo "App notarization did not return a submission identifier." >&2
        exit 69
    }
    submission_status=$(plutil -extract status raw "$submission_result")
    xcrun notarytool log \
        --keychain-profile "$notary_profile" \
        "$submission_id" \
        "$submission_log"
    submission_issue_count=$(plutil -extract issues raw "$submission_log")
    case "$submission_issue_count" in
        ''|*[!0-9]*) echo "App notarization returned an invalid issue list." >&2; exit 65 ;;
    esac
    if test "$submission_exit" -ne 0 \
        || test "$submission_status" != Accepted \
        || test "$submission_issue_count" -ne 0; then
        echo "App notarization was not accepted without issues. Submission: $submission_id" >&2
        plutil -p "$submission_log" >&2
        exit 65
    fi
    xcrun stapler staple "$app_path"
    xcrun stapler validate "$app_path"
    spctl --assess --type execute --verbose=2 "$app_path"
fi

dist_directory=${ISSUELIGHT_DIST_DIRECTORY:-"$repository_root/dist"}
case "$dist_directory" in
    /) echo "The dist directory must not be the filesystem root." >&2; exit 65 ;;
    /*) ;;
    *) echo "The dist directory must be absolute." >&2; exit 65 ;;
esac
test ! -L "$dist_directory" || {
    echo "Refusing to replace a symbolic-link dist directory." >&2
    exit 65
}
if test -e "$dist_directory"; then
    test -d "$dist_directory" || {
        echo "The dist path exists and is not a directory: $dist_directory" >&2
        exit 73
    }
    test -z "$(find "$dist_directory" -mindepth 1 -maxdepth 1 -print -quit)" || {
        echo "Refusing to overwrite a non-empty dist directory: $dist_directory" >&2
        exit 73
    }
else
    mkdir "$dist_directory"
fi

revision=$(git rev-parse HEAD)
if test "$identity" = -; then
    verification_mode=--allow-unsigned
    artifact_suffix=-UNSIGNED
else
    verification_mode=signed
    artifact_suffix=
    signature_details=$(codesign -d --verbose=4 "$app_path" 2>&1)
    signed_team=$(printf '%s\n' "$signature_details" | sed -n 's/^TeamIdentifier=//p')
    test -n "$signed_team" || {
        echo "The signed app has no Apple team identifier." >&2
        exit 65
    }
    if test -n "${APPLE_TEAM_ID:-}" && test "$APPLE_TEAM_ID" != "$signed_team"; then
        echo "The signed app belongs to an unexpected Apple team." >&2
        exit 65
    fi
    APPLE_TEAM_ID=$signed_team
    export APPLE_TEAM_ID
fi

scripts/package_release.sh \
    "$app_path" \
    "$dist_directory" \
    "$version" \
    "$revision" \
    "$verification_mode"

dmg_path="$dist_directory/IssueLight-$version-macos-universal$artifact_suffix.dmg"
dmg_root="$package_work_directory/DMG"
mkdir "$dmg_root"
ditto "$app_path" "$dmg_root/IssueLight.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create \
    -volname "IssueLight $version" \
    -srcfolder "$dmg_root" \
    -format UDZO \
    -ov \
    "$dmg_path"
hdiutil verify "$dmg_path"

if test -n "$notary_profile"; then
    dmg_submission_result="$package_work_directory/dmg-notary-result.plist"
    dmg_submission_log="$package_work_directory/dmg-notary-log.json"
    dmg_submission_exit=0
    xcrun notarytool submit "$dmg_path" \
        --keychain-profile "$notary_profile" \
        --wait \
        --timeout 90m \
        --output-format plist > "$dmg_submission_result" || dmg_submission_exit=$?
    dmg_submission_id=$(plutil -extract id raw "$dmg_submission_result" 2>/dev/null) || {
        echo "DMG notarization did not return a submission identifier." >&2
        exit 69
    }
    dmg_submission_status=$(plutil -extract status raw "$dmg_submission_result")
    xcrun notarytool log \
        --keychain-profile "$notary_profile" \
        "$dmg_submission_id" \
        "$dmg_submission_log"
    dmg_submission_issue_count=$(plutil -extract issues raw "$dmg_submission_log")
    case "$dmg_submission_issue_count" in
        ''|*[!0-9]*) echo "DMG notarization returned an invalid issue list." >&2; exit 65 ;;
    esac
    if test "$dmg_submission_exit" -ne 0 \
        || test "$dmg_submission_status" != Accepted \
        || test "$dmg_submission_issue_count" -ne 0; then
        echo "DMG notarization was not accepted without issues. Submission: $dmg_submission_id" >&2
        plutil -p "$dmg_submission_log" >&2
        exit 65
    fi
    xcrun stapler staple "$dmg_path"
    xcrun stapler validate "$dmg_path"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"
fi

(
    cd "$dist_directory"
    shasum -a 256 ./*.zip ./*.dmg ./*.spdx.json > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)

echo "Release artifacts written to $dist_directory"
