#!/bin/sh

set -eu

usage() {
    echo "Usage: $0 COVERAGE_JSON MINIMUM_LINE_PERCENT MINIMUM_REGION_PERCENT" >&2
    exit 64
}

test "$#" -eq 3 || usage

coverage_json=$1
minimum_lines=$2
minimum_regions=$3

test -f "$coverage_json" || {
    echo "Coverage JSON does not exist: $coverage_json" >&2
    exit 66
}
printf '%s\n' "$minimum_lines" | grep -Eq '^[0-9]+([.][0-9]+)?$' || usage
printf '%s\n' "$minimum_regions" | grep -Eq '^[0-9]+([.][0-9]+)?$' || usage
for minimum in "$minimum_lines" "$minimum_regions"; do
    if ! awk -v value="$minimum" 'BEGIN { exit !(value >= 0 && value <= 100) }'; then
        echo "Coverage thresholds must be between 0 and 100." >&2
        exit 65
    fi
done

line_coverage=$(
    /usr/bin/plutil -extract data.0.totals.lines.percent raw -o - "$coverage_json"
)
region_coverage=$(
    /usr/bin/plutil -extract data.0.totals.regions.percent raw -o - "$coverage_json"
)

failed=0
if ! awk -v actual="$line_coverage" -v minimum="$minimum_lines" \
    'BEGIN { exit !(actual + 0 >= minimum + 0) }'; then
    printf 'Line coverage %s%% is below the %s%% ratchet.\n' \
        "$line_coverage" "$minimum_lines" >&2
    failed=1
fi
if ! awk -v actual="$region_coverage" -v minimum="$minimum_regions" \
    'BEGIN { exit !(actual + 0 >= minimum + 0) }'; then
    printf 'Region coverage %s%% is below the %s%% ratchet.\n' \
        "$region_coverage" "$minimum_regions" >&2
    failed=1
fi
test "$failed" -eq 0 || exit 1

printf 'Core coverage ratchet passed: %s%% lines, %s%% regions.\n' \
    "$line_coverage" "$region_coverage"
