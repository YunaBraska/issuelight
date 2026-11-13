#!/bin/sh

set -eu

usage() {
    echo "Usage: $0 APP_PATH OUTPUT_DIRECTORY VERSION REVISION [--allow-unsigned]" >&2
    exit 64
}

test "$#" -eq 4 || test "$#" -eq 5 || usage

app_path=$1
output_directory=$2
version=$3
revision=$4
verification_mode=${5:-signed}

case "$app_path" in
    /*.app) ;;
    *) echo "APP_PATH must be an absolute .app path." >&2; exit 65 ;;
esac
case "$output_directory" in
    /) echo "OUTPUT_DIRECTORY must not be the filesystem root." >&2; exit 65 ;;
    /*) ;;
    *) echo "OUTPUT_DIRECTORY must be absolute." >&2; exit 65 ;;
esac
case "$version" in
    ''|*[!A-Za-z0-9._-]*) echo "VERSION contains unsupported characters." >&2; exit 65 ;;
esac
case "$version" in
    [A-Za-z0-9]*) ;;
    *) echo "VERSION must begin with a letter or number." >&2; exit 65 ;;
esac
case "$revision" in
    ''|*[!0-9a-f]*) echo "REVISION must be a lowercase hexadecimal Git revision." >&2; exit 65 ;;
esac
test "${#revision}" -ge 7 || { echo "REVISION is too short." >&2; exit 65; }
test "${#revision}" -le 64 || { echo "REVISION is too long." >&2; exit 65; }
test "$verification_mode" = "signed" || test "$verification_mode" = "--allow-unsigned" || usage

test -d "$app_path" || { echo "App bundle does not exist: $app_path" >&2; exit 66; }
app_path=$(cd "$app_path" && pwd -P)
test "$(basename "$app_path")" = "IssueLight.app" || {
    echo "App bundle must be named IssueLight.app." >&2
    exit 65
}
info_plist="$app_path/Contents/Info.plist"
executable="$app_path/Contents/MacOS/IssueLight"
test -f "$info_plist" || { echo "App Info.plist is missing." >&2; exit 66; }
test -f "$executable" || { echo "App executable is missing." >&2; exit 66; }

bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
bundle_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")
test "$bundle_identifier" = "io.github.yunabraska.issuelight" || {
    echo "Unexpected bundle identifier: $bundle_identifier" >&2
    exit 65
}
test "$bundle_version" = "$version" || {
    echo "Bundle version $bundle_version does not match requested version $version." >&2
    exit 65
}
case "$bundle_build" in
    ''|*[!0-9]*|0) echo "Bundle build number must be a positive integer." >&2; exit 65 ;;
esac
test ! -e "$app_path/Contents/MacOS/IssueLight.debug.dylib" || {
    echo "Debug app bundles cannot be packaged as releases." >&2
    exit 65
}
test ! -e "$app_path/Contents/MacOS/__preview.dylib" || {
    echo "Preview-enabled app bundles cannot be packaged as releases." >&2
    exit 65
}

architectures=$(lipo -archs "$executable")
case " $architectures " in
    *' arm64 '*) ;;
    *) echo "Release executable is missing arm64." >&2; exit 65 ;;
esac
case " $architectures " in
    *' x86_64 '*) ;;
    *) echo "Release executable is missing x86_64." >&2; exit 65 ;;
esac
if nm "$executable" 2>/dev/null | grep -q '__llvm_profile'; then
    echo "Release executable contains code-coverage instrumentation." >&2
    exit 65
fi

if test "$verification_mode" = "signed"; then
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
    printf '%s\n' "$signature_details" | grep -q '^Timestamp=' || {
        echo "Release app is missing a secure signature timestamp." >&2
        exit 65
    }
    test -n "${APPLE_TEAM_ID:-}" || {
        echo "APPLE_TEAM_ID is required for release identity verification." >&2
        exit 65
    }
    signed_team=$(printf '%s\n' "$signature_details" | sed -n 's/^TeamIdentifier=//p')
    test "$signed_team" = "$APPLE_TEAM_ID" || {
        echo "Release app was signed by an unexpected Apple team." >&2
        exit 65
    }
    release_entitlements=$(codesign -d --entitlements :- "$app_path" 2>/dev/null)
    if printf '%s\n' "$release_entitlements" \
        | plutil -extract 'com\.apple\.security\.get-task-allow' raw - 2>/dev/null \
        | grep -q '^true$'; then
        echo "Release app must not enable com.apple.security.get-task-allow." >&2
        exit 65
    fi
    xcrun stapler validate "$app_path"
    spctl --assess --type execute "$app_path"
fi

if find "$app_path" \( -name '*.key' -o -name '*.p12' -o -name '*.pfx' -o -name '.env.local' \) -print -quit | grep -q .; then
    echo "Release bundle contains a forbidden secret-bearing file type." >&2
    exit 65
fi

if test "$verification_mode" = "--allow-unsigned"; then
    artifact_suffix=-UNSIGNED
else
    artifact_suffix=
fi
archive_name="IssueLight-$version-macos-universal$artifact_suffix.zip"
sbom_name="IssueLight-$version$artifact_suffix.spdx.json"
mkdir -p "$output_directory"
canonical_app_path=$app_path
canonical_output_directory=$(cd "$output_directory" && pwd -P)
case "$canonical_output_directory/" in
    "$canonical_app_path/"*)
        echo "OUTPUT_DIRECTORY must not be inside the app bundle." >&2
        exit 65
        ;;
esac

archive_path="$canonical_output_directory/$archive_name"
sbom_path="$canonical_output_directory/$sbom_name"
checksum_path="$canonical_output_directory/SHA256SUMS"
lock_directory="$canonical_output_directory/.issuelight-package.lock"
mkdir "$lock_directory" 2>/dev/null || {
    echo "Another packaging operation already owns this output directory." >&2
    exit 75
}

staging_directory=
staging_archive=
staging_sbom=
staging_checksums=
cleanup() {
    if test -n "$staging_directory"; then
        rm -f "$staging_archive" "$staging_sbom" "$staging_checksums"
        rmdir "$staging_directory" 2>/dev/null || true
    fi
    rmdir "$lock_directory" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

for output_path in "$archive_path" "$sbom_path" "$checksum_path"; do
    test ! -e "$output_path" && test ! -L "$output_path" || {
        echo "Refusing to overwrite existing release output: $output_path" >&2
        exit 73
    }
done

staging_directory=$(mktemp -d "$canonical_output_directory/.issuelight-package.XXXXXX")
staging_archive="$staging_directory/$archive_name"
staging_sbom="$staging_directory/$sbom_name"
staging_checksums="$staging_directory/SHA256SUMS"

ditto -c -k --sequesterRsrc --keepParent "$canonical_app_path" "$staging_archive"
unzip -tq "$staging_archive"
xcrun swift "$(dirname "$0")/generate_spdx_sbom.swift" \
    "$version" \
    "$bundle_build" \
    "$revision" \
    "$staging_sbom"

(
    cd "$staging_directory"
    shasum -a 256 "$archive_name" "$sbom_name" > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)

mv "$staging_archive" "$archive_path"
mv "$staging_sbom" "$sbom_path"
mv "$staging_checksums" "$checksum_path"
rmdir "$staging_directory"
rmdir "$lock_directory"
trap - EXIT HUP INT TERM

echo "Release candidate written to $canonical_output_directory"
