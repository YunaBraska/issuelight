#!/bin/sh
set -eu

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
container_name=${ISSUELIGHT_CHECKMK_CONTAINER_NAME:-issuelight-checkmk-live}
image=${ISSUELIGHT_CHECKMK_IMAGE:-checkmk/check-mk-community@sha256:4677d9f8b11598252bf15cea61769e3dc20402908071e79448d3537acd8112f7}
api_secret=issuelight-live
endpoint=
startup_attempts=${ISSUELIGHT_CHECKMK_STARTUP_ATTEMPTS:-180}

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

cleanup_lab() {
  exit_status=$?
  trap - EXIT HUP INT TERM
  stop_lab
  exit "$exit_status"
}

resolve_endpoint() {
  port_mapping=$(docker_command port "$container_name" 5000/tcp | tail -n 1)
  port=${port_mapping##*:}
  case "$port" in
    ''|*[!0-9]*)
      printf 'Could not determine the Checkmk HTTP port.\n' >&2
      exit 1
      ;;
  esac
  endpoint="http://127.0.0.1:$port/cmk/check_mk/api/v1"
}

api_request() {
  curl --silent --show-error --fail-with-body \
    --header "Authorization: Bearer cmkadmin $api_secret" \
    --header 'Accept: application/json' \
    "$@"
}

api_post() {
  api_request \
    --request POST \
    --header 'Content-Type: application/json' \
    --data "$1" \
    "$2"
}

wait_for_api() {
  case "$startup_attempts" in
    ''|*[!0-9]*|0)
      printf 'ISSUELIGHT_CHECKMK_STARTUP_ATTEMPTS must be a positive integer.\n' >&2
      exit 64
      ;;
  esac
  attempt=0
  while [ "$attempt" -lt "$startup_attempts" ]; do
    if api_request "$endpoint/version" >/dev/null 2>&1; then
      return
    fi
    if [ "$(docker_command inspect --format '{{.State.Running}}' "$container_name")" != true ]; then
      docker_command logs "$container_name" >&2 || true
      printf 'Checkmk stopped before its API became reachable.\n' >&2
      exit 1
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  docker_command logs "$container_name" >&2 || true
  printf 'Checkmk did not become reachable.\n' >&2
  exit 1
}

set_problem_state() {
  # shellcheck disable=SC2016 # Expand the timestamp inside the container.
  docker_command exec --user cmk "$container_name" bash -lc \
    'now=$(date +%s); printf "COMMAND [%s] PROCESS_HOST_CHECK_RESULT;issuelight-live;1;DOWN - IssueLight live lab\n" "$now" | lq' \
    >/dev/null
}

wait_for_problem() {
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    host_data=$(api_post \
      '{"columns":["name","state","plugin_output","acknowledged","scheduled_downtime_depth"],"query":{"op":"=","left":"name","right":"issuelight-live"}}' \
      "$endpoint/domain-types/host/collections/all")
    if printf '%s' "$host_data" | jq --exit-status \
      '.value | any(.[]; .extensions.name == "issuelight-live" and .extensions.state == 1 and .extensions.plugin_output == "DOWN - IssueLight live lab")' \
      >/dev/null; then
      return
    fi
    set_problem_state
    attempt=$((attempt + 1))
    sleep 1
  done
  printf 'The deterministic Checkmk host problem did not reach DOWN.\n' >&2
  exit 1
}

start_lab() {
  if docker_command container inspect "$container_name" >/dev/null 2>&1; then
    printf 'Container %s already exists. Run %s stop first.\n' "$container_name" "$0" >&2
    exit 1
  fi

  docker_command run --detach \
    --name "$container_name" \
    --env "CMK_PASSWORD=$api_secret" \
    --env 'TZ=UTC' \
    --tmpfs /opt/omd/sites/cmk/tmp:uid=1000,gid=1000 \
    --publish 127.0.0.1::5000 \
    "$image" >/dev/null
  resolve_endpoint
  wait_for_api

  api_post \
    '{"host_name":"issuelight-live","folder":"/","attributes":{"alias":"IssueLight live lab","ipaddress":"192.0.2.1","tag_agent":"no-agent","tag_snmp_ds":"no-snmp"}}' \
    "$endpoint/domain-types/host_config/collections/all" >/dev/null
  docker_command exec --user cmk "$container_name" bash -lc 'cmk -R' >/dev/null
  set_problem_state
  wait_for_problem
}

verify_api() {
  api_request "$endpoint/version" | jq --exit-status \
    '.site == "cmk" and (.versions.checkmk | length > 0)' >/dev/null
  api_post \
    '{"columns":["name","state","plugin_output"],"query":{"op":"=","left":"name","right":"issuelight-live"}}' \
    "$endpoint/domain-types/host/collections/all" \
    | jq --exit-status \
      '.value | any(.[]; .extensions.name == "issuelight-live" and .extensions.state == 1)' \
      >/dev/null

  api_post \
    '{"acknowledge_type":"host","host_name":"issuelight-live","comment":"IssueLight API qualification","sticky":true,"notify":false,"persistent":false}' \
    "$endpoint/domain-types/acknowledge/collections/host" >/dev/null
  start_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  end_time=$(date -u -v+5M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -d '+5 minutes' '+%Y-%m-%dT%H:%M:%SZ')
  api_post \
    "{\"downtime_type\":\"host\",\"host_name\":\"issuelight-live\",\"start_time\":\"$start_time\",\"end_time\":\"$end_time\",\"recur\":\"fixed\",\"duration\":0,\"comment\":\"IssueLight API qualification\"}" \
    "$endpoint/domain-types/downtime/collections/host" >/dev/null

  attempt=0
  while [ "$attempt" -lt 20 ]; do
    host_data=$(api_post \
      '{"columns":["name","acknowledged","scheduled_downtime_depth"],"query":{"op":"=","left":"name","right":"issuelight-live"}}' \
      "$endpoint/domain-types/host/collections/all")
    if printf '%s' "$host_data" | jq --exit-status \
      '.value | any(.[]; .extensions.name == "issuelight-live" and .extensions.acknowledged == 1 and .extensions.scheduled_downtime_depth > 0)' \
      >/dev/null; then
      return
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  printf 'Checkmk did not apply acknowledgement and downtime.\n' >&2
  exit 1
}

print_status() {
  if ! docker_command container inspect "$container_name" >/dev/null 2>&1; then
    printf 'Checkmk lab is stopped.\n'
    return
  fi
  resolve_endpoint
  printf 'Checkmk lab: running\n'
  printf 'API: %s\n' "$endpoint"
  printf 'Web: %s\n' "${endpoint%/check_mk/api/v1}"
  printf 'API user: cmkadmin\n'
  printf 'API secret: %s\n' "$api_secret"
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
    printf 'Checkmk lab stopped.\n'
    ;;
  status)
    print_status
    ;;
  api-test)
    trap cleanup_lab EXIT HUP INT TERM
    start_lab
    verify_api
    printf 'Checkmk REST API integration passed.\n'
    ;;
  test)
    require_command swift
    trap cleanup_lab EXIT HUP INT TERM
    start_lab
    ISSUELIGHT_LIVE_CHECKMK_URL=$endpoint \
      ISSUELIGHT_CHECKMK_API_SECRET=$api_secret \
      swift test \
        --package-path "$repository_root/Packages/IssueLightCore" \
        --filter CheckmkLiveConnectionTests
    printf 'Checkmk provider integration passed.\n'
    ;;
  *)
    printf 'Usage: %s {start|stop|status|api-test|test}\n' "$0" >&2
    exit 64
    ;;
esac
