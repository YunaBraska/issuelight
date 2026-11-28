#!/bin/sh
set -eu

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
container_name=${ISSUELIGHT_NAGIOS_CONTAINER_NAME:-issuelight-nagioscore-live}
image=${ISSUELIGHT_NAGIOS_IMAGE:-issuelight-nagioscore-live:4.5.14}
password=issuelight-live
endpoint=
lab_temp_directory=
swift_scratch_path=${ISSUELIGHT_SWIFT_SCRATCH_PATH:-}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Required command is missing: %s\n' "$1" >&2
    exit 1
  fi
}

docker_command() {
  docker "$@"
}

stop_lab() {
  if docker_command container inspect "$container_name" >/dev/null 2>&1; then
    docker_command container rm --force "$container_name" >/dev/null
  fi
}

remove_temp_directory() {
  if [ -n "$lab_temp_directory" ] && [ -d "$lab_temp_directory" ]; then
    lab_temp_root=${TMPDIR:-/tmp}
    lab_temp_root=${lab_temp_root%/}
    case "$lab_temp_directory" in
      "$lab_temp_root"/issuelight-nagios.*) rm -rf "$lab_temp_directory" ;;
      *) printf 'Refusing to clean unexpected lab directory: %s\n' "$lab_temp_directory" >&2 ;;
    esac
  fi
}

cleanup_lab() {
  exit_status=$?
  trap - EXIT HUP INT TERM
  stop_lab
  remove_temp_directory
  exit "$exit_status"
}

resolve_endpoint() {
  port_mapping=$(docker_command port "$container_name" 80/tcp | tail -n 1)
  port=${port_mapping##*:}
  case "$port" in
    ''|*[!0-9]*)
      printf 'Could not determine the Nagios Core HTTP port.\n' >&2
      exit 1
      ;;
  esac
  endpoint="http://127.0.0.1:$port/nagios/cgi-bin/statusjson.cgi"
}

api_request() {
  curl --silent --show-error --fail-with-body \
    --user "nagiosadmin:$password" \
    "$@"
}

wait_for_api() {
  attempt=0
  while [ "$attempt" -lt 60 ]; do
    if api_request "$endpoint?query=programstatus" >/dev/null 2>&1; then
      return
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  docker_command logs "$container_name" >&2 || true
  printf 'Nagios Core did not become reachable.\n' >&2
  exit 1
}

wait_for_command_pipe() {
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    if docker_command exec "$container_name" \
      test -p /usr/local/nagios/var/rw/nagios.cmd; then
      return
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  docker_command logs "$container_name" >&2 || true
  printf 'Nagios Core did not create its external command pipe.\n' >&2
  exit 1
}

inject_problems() {
  timestamp=$(date +%s)
  docker_command exec "$container_name" sh -c \
    'printf "[%s] PROCESS_HOST_CHECK_RESULT;issuelight-live;1;DOWN - IssueLight live lab\n[%s] PROCESS_SERVICE_CHECK_RESULT;issuelight-live;IssueLight Critical Service;2;CRITICAL - IssueLight live lab\n" "$1" "$1" > /usr/local/nagios/var/rw/nagios.cmd' \
    sh "$timestamp"
}

wait_for_problems() {
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    host_data=$(api_request "$endpoint?query=hostlist&details=true")
    service_data=$(api_request "$endpoint?query=servicelist&details=true")
    if printf '%s' "$host_data" | jq --exit-status \
      '.result.type_code == 0 and .data.hostlist["issuelight-live"].status == 4' \
      >/dev/null \
      && printf '%s' "$service_data" | jq --exit-status \
      '.result.type_code == 0 and .data.servicelist["issuelight-live"]["IssueLight Critical Service"].status == 16' \
      >/dev/null; then
      return
    fi
    inject_problems
    attempt=$((attempt + 1))
    sleep 1
  done
  printf 'The deterministic Nagios Core problems did not become visible.\n' >&2
  exit 1
}

build_image() {
  docker_command build \
    --tag "$image" \
    "$repository_root/integration/nagioscore" >/dev/null
}

start_lab() {
  if docker_command container inspect "$container_name" >/dev/null 2>&1; then
    printf 'Container %s already exists. Run %s stop first.\n' "$container_name" "$0" >&2
    exit 1
  fi

  build_image
  docker_command run --detach \
    --name "$container_name" \
    --env "ISSUELIGHT_NAGIOS_PASSWORD=$password" \
    --publish 127.0.0.1::80 \
    "$image" >/dev/null
  resolve_endpoint
  wait_for_api
  wait_for_command_pipe
  inject_problems
  wait_for_problems
}

verify_command_cgi() {
  lab_temp_root=${TMPDIR:-/tmp}
  lab_temp_root=${lab_temp_root%/}
  lab_temp_directory=$(mktemp -d "$lab_temp_root/issuelight-nagios.XXXXXX")
  cookie_file="$lab_temp_directory/cookies.txt"
  command_form="$lab_temp_directory/command.html"
  command_result="$lab_temp_directory/result.html"
  command_url=${endpoint%/statusjson.cgi}/cmd.cgi

  api_request \
    --cookie-jar "$cookie_file" \
    --output "$command_form" \
    "$command_url?cmd_typ=96&host=issuelight-live"
  form_id=$(sed -n "s/.*NAME='nagFormId' VALUE='\([0-9A-Fa-f][0-9A-Fa-f]*\)'.*/\1/p" "$command_form" | head -n 1)
  start_time=$(sed -n "s/.*NAME='start_time' VALUE='\([^']*\)'.*/\1/p" "$command_form" | head -n 1)
  test -n "$form_id"
  test -n "$start_time"

  api_request \
    --cookie "$cookie_file" \
    --request POST \
    --data-urlencode 'cmd_typ=96' \
    --data-urlencode 'cmd_mod=2' \
    --data-urlencode 'host=issuelight-live' \
    --data-urlencode "nagFormId=$form_id" \
    --data-urlencode "start_time=$start_time" \
    --data-urlencode 'force_check=on' \
    --data-urlencode 'btnSubmit=Commit' \
    --output "$command_result" \
    "$command_url"
  grep -F 'Your command request was successfully submitted to Nagios for processing.' \
    "$command_result" >/dev/null
}

verify_api() {
  api_request "$endpoint?query=programstatus" \
    | jq --exit-status \
      '.result.cgi == "statusjson.cgi" and .result.query == "programstatus" and .result.type_code == 0' \
      >/dev/null
  api_request "$endpoint?query=hostlist&details=true&hoststatus=down%20unreachable" \
    | jq --exit-status \
      '.data.hostlist["issuelight-live"].plugin_output == "DOWN - IssueLight live lab"' \
      >/dev/null
  api_request "$endpoint?query=servicelist&details=true&servicestatus=warning%20unknown%20critical" \
    | jq --exit-status \
      '.data.servicelist["issuelight-live"]["IssueLight Critical Service"].plugin_output == "CRITICAL - IssueLight live lab"' \
      >/dev/null
  status_code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --user 'nagiosadmin:wrong-password' "$endpoint?query=programstatus")
  test "$status_code" = 401
  verify_command_cgi
  inject_problems
  wait_for_problems
}

print_status() {
  if ! docker_command container inspect "$container_name" >/dev/null 2>&1; then
    printf 'Nagios Core lab is stopped.\n'
    return
  fi
  resolve_endpoint
  printf 'Nagios Core lab: running\n'
  printf 'API: %s\n' "$endpoint"
  printf 'Web: %s\n' "${endpoint%/cgi-bin/statusjson.cgi}"
  printf 'Basic user: nagiosadmin\n'
  printf 'Basic password: %s\n' "$password"
}

require_command docker
require_command curl
require_command jq

case "${1:-}" in
  start)
    trap cleanup_lab EXIT HUP INT TERM
    start_lab
    trap - EXIT HUP INT TERM
    print_status
    ;;
  stop)
    stop_lab
    printf 'Nagios Core lab stopped.\n'
    ;;
  status)
    print_status
    ;;
  api-test)
    trap cleanup_lab EXIT HUP INT TERM
    start_lab
    verify_api
    printf 'Nagios Core CGI integration passed.\n'
    ;;
  test)
    require_command swift
    trap cleanup_lab EXIT HUP INT TERM
    start_lab
    verify_api
    set -- \
      --package-path "$repository_root/Packages/IssueLightCore" \
      --filter NagiosCoreLiveConnectionTests
    if [ -n "$swift_scratch_path" ]; then
      set -- "$@" --scratch-path "$swift_scratch_path"
    fi
    ISSUELIGHT_LIVE_NAGIOS_URL=$endpoint \
      ISSUELIGHT_NAGIOS_PASSWORD=$password \
      swift test "$@"
    printf 'Nagios Core provider integration passed.\n'
    ;;
  *)
    printf 'Usage: %s {start|stop|status|api-test|test}\n' "$0" >&2
    exit 64
    ;;
esac
