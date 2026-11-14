#!/bin/sh

set -eu

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH='' cd -- "$script_directory/.." && pwd)
environment_file="$repository_root/integration/icinga2/.env.local"
review_bundle_identifier=berlin.yuna.issuelight.review
review_source_id=11111111-1111-4111-8111-111111111111
review_product_name='IssueLight Review'
review_derived_data=${TMPDIR:-/tmp}/issuelight-review-derived
review_seed_binary=${TMPDIR:-/tmp}/issuelight-review-source-seed
user_name=$(id -un)
user_directory=$(dscl . -read "/Users/$user_name" NFSHomeDirectory | awk '{print $2}')
review_app_directory="$user_directory/Applications"
review_app="$review_app_directory/$review_product_name.app"
review_sources_directory="$user_directory/Library/Application Support/$review_bundle_identifier"
review_sources_file="$review_sources_directory/sources.json"

if [ ! -f "$environment_file" ]; then
    printf 'Missing %s. Configure the local Icinga review lab first.\n' "$environment_file" >&2
    exit 2
fi

set -a
# shellcheck source=/dev/null
. "$environment_file"
set +a

: "${ISSUELIGHT_ICINGA_BASIC_PASSWORD:?missing in .env.local}"
: "${ISSUELIGHT_ICINGA_PORT:=5665}"

"$repository_root/scripts/icinga2_lab.sh" start

xcodebuild build -quiet \
    -project "$repository_root/IssueLight/IssueLight.xcodeproj" \
    -scheme IssueLight \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$review_derived_data" \
    PRODUCT_BUNDLE_IDENTIFIER="$review_bundle_identifier" \
    PRODUCT_NAME="$review_product_name" \
    INFOPLIST_KEY_CFBundleDisplayName="$review_product_name" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM=

built_app="$review_derived_data/Build/Products/Debug/$review_product_name.app"
test -d "$built_app"
review_process=$(pgrep -x "$review_product_name" | head -1 || true)
if [ -n "$review_process" ]; then
    kill "$review_process"
    attempt=0
    while pgrep -x "$review_product_name" >/dev/null && [ "$attempt" -lt 10 ]; do
        sleep 1
        attempt=$((attempt + 1))
    done
fi
mkdir -p "$review_app_directory"
ditto "$built_app" "$review_app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$review_app"
codesign --verify --deep --strict "$review_app"

xcrun swiftc \
    "$repository_root/Packages/IssueLightCore/Sources/IssueLightCore/MonitoringSource.swift" \
    "$repository_root/Packages/IssueLightCore/Sources/IssueLightCore/ServerCertificateFingerprint.swift" \
    "$repository_root/Packages/IssueLightCore/Sources/IssueLightCore/SourceStore.swift" \
    "$repository_root/scripts/seed_review_source.swift" \
    -o "$review_seed_binary"
"$review_seed_binary" "$review_sources_file" "$ISSUELIGHT_ICINGA_PORT"

credential_label="IssueLight Basic credential $review_source_id"
security delete-internet-password \
    -l "$credential_label" >/dev/null 2>&1 || true
printf '%s\n' "$ISSUELIGHT_ICINGA_BASIC_PASSWORD" | \
    "$review_app/Contents/MacOS/$review_product_name" \
        --seed-review-password "https://localhost:$ISSUELIGHT_ICINGA_PORT"

open -a "$review_app"

printf 'Review app opened: %s\n' "$review_app"
printf 'Review source: https://localhost:%s with real Icinga 2 fixture data\n' "$ISSUELIGHT_ICINGA_PORT"
