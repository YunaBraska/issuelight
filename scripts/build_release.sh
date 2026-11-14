#!/bin/sh

set -eu

script_directory=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
repository_root=$(CDPATH='' cd "$script_directory/.." && pwd -P)
environment_file="$repository_root/.env.local"

if [ -f "$environment_file" ]; then
    set -a
    . "$environment_file"
    set +a
fi

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

: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${APPLE_SIGNING_IDENTITY:?APPLE_SIGNING_IDENTITY is required}"
: "${NOTARY_KEYCHAIN_PROFILE:?NOTARY_KEYCHAIN_PROFILE is required}"
case "$APPLE_TEAM_ID" in
    *[!A-Z0-9]*|'') echo "APPLE_TEAM_ID must contain only uppercase letters and numbers." >&2; exit 65 ;;
esac
test "${#APPLE_TEAM_ID}" -eq 10 || {
    echo "APPLE_TEAM_ID must contain exactly 10 characters." >&2
    exit 65
}
case "$APPLE_SIGNING_IDENTITY" in
    Developer\ ID\ Application:*) ;;
    *) echo "APPLE_SIGNING_IDENTITY must name a Developer ID Application identity." >&2; exit 65 ;;
esac

test "$revision" = "$(git -C "$repository_root" rev-parse HEAD)" || {
    echo "REVISION does not match the checked-out commit." >&2
    exit 65
}
test -z "$(git -C "$repository_root" status --porcelain --untracked-files=all)" || {
    echo "Release builds require a clean working tree." >&2
    exit 65
}

version=$(xcodebuild \
    -project "$repository_root/IssueLight/IssueLight.xcodeproj" \
    -scheme IssueLight \
    -configuration Release \
    -showBuildSettings \
    | awk '/^[[:space:]]*MARKETING_VERSION = / { print $3; exit }')
test -n "$version" || {
    echo "Could not resolve the release version." >&2
    exit 65
}

MACOS_SIGNING_IDENTITY=$APPLE_SIGNING_IDENTITY
MACOS_NOTARY_PROFILE=$NOTARY_KEYCHAIN_PROFILE
ISSUELIGHT_DIST_DIRECTORY=$output_directory
export APPLE_TEAM_ID MACOS_SIGNING_IDENTITY MACOS_NOTARY_PROFILE ISSUELIGHT_DIST_DIRECTORY
exec "$script_directory/package.sh" "$version"
