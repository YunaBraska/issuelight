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
update_private_key=${MACOS_UPDATE_PRIVATE_KEY:-}
update_public_key=${MACOS_UPDATE_PUBLIC_KEY:-}
build_number=${GITHUB_RUN_ID:-1}
signing_flags=
case "$build_number" in
    ''|*[!0-9]*|0) echo "The build number must be a positive integer." >&2; exit 65 ;;
esac
if test -n "$notary_profile" && test "$identity" = -; then
    echo "Notarization requires a Developer ID signing identity." >&2
    exit 65
fi
if test -n "$update_public_key" || test -n "$update_private_key"; then
    test -n "$update_public_key" || {
        echo "MACOS_UPDATE_PUBLIC_KEY is required with MACOS_UPDATE_PRIVATE_KEY." >&2
        exit 65
    }
    test -n "$update_private_key" || {
        echo "MACOS_UPDATE_PRIVATE_KEY is required with MACOS_UPDATE_PUBLIC_KEY." >&2
        exit 65
    }
    for update_key_value in "$update_public_key" "$update_private_key"; do
        case "$update_key_value" in
            *[!A-Za-z0-9+/=]*)
                echo "Update keys must be 32-byte Base64 values." >&2
                exit 65
                ;;
            *=) ;;
            *)
                echo "Update keys must be 32-byte Base64 values." >&2
                exit 65
                ;;
        esac
        test "${#update_key_value}" -eq 44 || {
            echo "Update keys must be 32-byte Base64 values." >&2
            exit 65
        }
    done
fi
if test "$identity" != -; then
    test -n "$notary_profile" || {
        echo "A publishable Developer ID build requires notarization." >&2
        exit 65
    }
    test -n "$update_public_key" && test -n "$update_private_key" || {
        echo "A publishable direct release requires signed-update keys." >&2
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

if test -n "$update_private_key"; then
    update_private_key_raw="$package_work_directory/update-private-key.raw"
    update_public_key_raw="$package_work_directory/update-public-key.raw"
    printf '%s' "$update_private_key" | base64 -D > "$update_private_key_raw"
    printf '%s' "$update_public_key" | base64 -D > "$update_public_key_raw"
    test "$(wc -c < "$update_private_key_raw" | tr -d ' ')" -eq 32
    test "$(wc -c < "$update_public_key_raw" | tr -d ' ')" -eq 32
    update_key_der="$package_work_directory/update-key.der"
    {
        printf '\060\056\002\001\000\060\005\006\003\053\145\160\004\042\004\040'
        dd if="$update_private_key_raw" bs=32 count=1 2>/dev/null
    } > "$update_key_der"
    derived_update_public_key=$(openssl pkey \
        -inform DER \
        -in "$update_key_der" \
        -pubout \
        -outform DER \
        | tail -c 32 \
        | base64)
    test "$derived_update_public_key" = "$update_public_key" || {
        echo "MACOS_UPDATE_PUBLIC_KEY does not match MACOS_UPDATE_PRIVATE_KEY." >&2
        exit 65
    }
fi

derived_data_path="$package_work_directory/DerivedData"
cd "$repository_root"
set -- xcodebuild build \
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
"$@"

app_path="$derived_data_path/Build/Products/Release/IssueLight.app"
test -d "$app_path" || {
    echo "Release app was not built." >&2
    exit 66
}
test -d "$app_path/Contents/Frameworks/Sparkle.framework" || {
    echo "Direct release app is missing Sparkle.framework." >&2
    exit 66
}
test -f "$app_path/Contents/Resources/Sparkle-LICENSE.txt" || {
    echo "Direct release app is missing the Sparkle license notice." >&2
    exit 66
}
if test -n "$update_public_key"; then
    info_plist="$app_path/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c \
        'Add :SUFeedURL string https://github.com/YunaBraska/issuelight/releases/latest/download/appcast.xml' \
        "$info_plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $update_public_key" "$info_plist"
    /usr/libexec/PlistBuddy -c 'Add :SUEnableAutomaticChecks bool true' "$info_plist"
    /usr/libexec/PlistBuddy -c 'Add :SUAutomaticallyUpdate bool false' "$info_plist"
    /usr/libexec/PlistBuddy -c 'Add :SUVerifyUpdateBeforeExtraction bool true' "$info_plist"
    /usr/libexec/PlistBuddy -c 'Add :SURequireSignedFeed bool true' "$info_plist"
fi

if test "$identity" = -; then
    # Hardened Runtime library validation requires a real signing team. Keeping
    # it on an ad-hoc app makes dyld reject the embedded Sparkle framework.
    codesign --force --sign - --timestamp=none "$app_path"
else
    framework_directory="$app_path/Contents/Frameworks"
    if test -d "$framework_directory"; then
        find "$framework_directory" -type f -perm -111 -print | while IFS= read -r executable; do
            if file -b "$executable" | grep -q 'Mach-O'; then
                codesign --force --sign "$identity" --options runtime --timestamp \
                    --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$executable"
            fi
        done
        find "$framework_directory" -type d \
            \( -name '*.app' -o -name '*.appex' -o -name '*.xpc' \) -depth -print | while IFS= read -r bundle; do
            codesign --force --sign "$identity" --options runtime --timestamp \
                --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$bundle"
        done
        find "$framework_directory" -type d -name '*.framework' -depth -print | while IFS= read -r framework; do
            codesign --force --sign "$identity" --options runtime --timestamp \
                --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$framework"
        done
    fi
    codesign --force --sign "$identity" --options runtime --timestamp \
        --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$app_path"
fi
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
    submission_issue_count=$(jq -e -r '.issues | if . == null then 0 elif type == "array" then length else error("Expected an issues array.") end' "$submission_log")
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
    codesign --force --sign "$identity" --timestamp "$dmg_path"
    codesign --verify --strict "$dmg_path"
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
    dmg_submission_issue_count=$(jq -e -r '.issues | if . == null then 0 elif type == "array" then length else error("Expected an issues array.") end' "$dmg_submission_log")
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

if test -n "$update_public_key"; then
    update_stage="$package_work_directory/SparkleUpdate"
    update_key="$update_stage/private-key"
    mkdir "$update_stage"
    (umask 077; printf '%s' "$update_private_key" > "$update_key")
    cp "$dmg_path" "$update_stage/"
    generate_appcast=$(find "$derived_data_path/SourcePackages" \
        -type f -name generate_appcast -print -quit)
    sign_update=$(find "$derived_data_path/SourcePackages" \
        -type f -name sign_update -print -quit)
    test -n "$generate_appcast" || {
        echo "Sparkle generate_appcast tool was not resolved." >&2
        exit 66
    }
    test -n "$sign_update" || {
        echo "Sparkle sign_update tool was not resolved." >&2
        exit 66
    }
    "$generate_appcast" \
        --ed-key-file "$update_key" \
        --download-url-prefix "https://github.com/YunaBraska/issuelight/releases/download/$version/" \
        --maximum-versions 1 \
        --disable-signing-warning \
        -o "$dist_directory/appcast.xml" \
        "$update_stage"
    "$sign_update" \
        --ed-key-file "$update_key" \
        "$dist_directory/appcast.xml" \
        --disable-signing-warning
    "$sign_update" \
        --ed-key-file "$update_key" \
        --verify "$dist_directory/appcast.xml"
fi

(
    cd "$dist_directory"
    set -- ./*.zip ./*.dmg ./*.spdx.json
    if test -f appcast.xml; then
        set -- "$@" appcast.xml
    fi
    shasum -a 256 "$@" > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)

echo "Release artifacts written to $dist_directory"
