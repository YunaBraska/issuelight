#!/bin/sh
set -eu

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
container_name=${ISSUELIGHT_THRUK_CONTAINER_NAME:-issuelight-thruk-live}
image=${ISSUELIGHT_THRUK_IMAGE:-consol/omd-labs-debian@sha256:e140902ba2bc2ba042836c5137fefab56d4b70716aae5d21f51a2afaf6fcb73f}
basic_password=issuelight-live
endpoint=
api_key=

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
  port_mapping=$(docker_command port "$container_name" 443/tcp | tail -n 1)
  port=${port_mapping##*:}
  case "$port" in
    ''|*[!0-9]*)
      printf 'Could not determine the Thruk HTTPS port.\n' >&2
      exit 1
      ;;
  esac
  endpoint="https://127.0.0.1:$port/demo/thruk/r/v1"
}

wait_for_web_server() {
  attempt=0
  while [ "$attempt" -lt 45 ]; do
    if curl --insecure --silent --output /dev/null \
      "${endpoint%/thruk/r/v1}/"; then
      return
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  docker_command logs "$container_name" >&2 || true
  printf 'Thruk did not become reachable.\n' >&2
  exit 1
}

request_with_api_key() {
  curl --insecure --silent --show-error \
    --header "X-Thruk-Auth-Key: $api_key" \
    --header 'X-Thruk-Auth-User: omdadmin' \
    "$@"
}

start_lab() {
  if docker_command container inspect "$container_name" >/dev/null 2>&1; then
    printf 'Container %s already exists. Run %s stop first.\n' "$container_name" "$0" >&2
    exit 1
  fi

  docker_command run --detach \
    --name "$container_name" \
    --publish 127.0.0.1::443 \
    "$image" >/dev/null
  resolve_endpoint
  wait_for_web_server

  docker_command exec "$container_name" \
    bash -lc "su - demo -c 'set_admin_password issuelight-live'" >/dev/null
  docker_command cp \
    "$repository_root/integration/thruk/objects.cfg" \
    "$container_name:/omd/sites/demo/etc/naemon/conf.d/issuelight.cfg"
  docker_command exec "$container_name" bash -lc \
    "chown demo:demo /omd/sites/demo/etc/naemon/conf.d/issuelight.cfg && su - demo -c 'omd reload naemon'" \
    >/dev/null

  api_key=$(docker_command exec "$container_name" cat /omd/sites/demo/var/thruk/secret.key)
  service_data=$(request_with_api_key \
    "$endpoint/services?columns=host_name,description,peer_key")
  backend_id=$(printf '%s' "$service_data" | jq --raw-output --exit-status \
    'map(select(.host_name == "issuelight-live" and .description == "IssueLight Critical Service"))[0].peer_key')
  request_with_api_key \
    --request POST \
    "$endpoint/sites/$backend_id/services/issuelight-live/IssueLight%20Critical%20Service/cmd/schedule_forced_svc_check" \
    >/dev/null

  attempt=0
  while [ "$attempt" -lt 20 ]; do
    service_state=$(request_with_api_key \
      "$endpoint/services?columns=host_name,description,state&state%5Bgt%5D=0")
    if printf '%s' "$service_state" | jq --exit-status \
      'any(.[]; .host_name == "issuelight-live" and .description == "IssueLight Critical Service" and .state == 2)' \
      >/dev/null; then
      return
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  printf 'The deterministic Thruk problem did not reach CRITICAL.\n' >&2
  exit 1
}

verify_api() {
  request_with_api_key "$endpoint/thruk" | jq --exit-status '.rest_version == 1' >/dev/null
  request_with_api_key \
    "$endpoint/services?columns=host_name,description,state,plugin_output,peer_key&state%5Bgt%5D=0" \
    | jq --exit-status \
      'any(.[]; .host_name == "issuelight-live" and .description == "IssueLight Critical Service" and .state == 2)' \
      >/dev/null
  response=$(request_with_api_key \
    --request POST \
    "$endpoint/services/issuelight-live/IssueLight%20Critical%20Service/cmd/schedule_forced_svc_check")
  printf '%s' "$response" | jq --exit-status \
    '.message == "Command successfully submitted"' >/dev/null
}

print_status() {
  if ! docker_command container inspect "$container_name" >/dev/null 2>&1; then
    printf 'Thruk lab is stopped.\n'
    return
  fi
  resolve_endpoint
  printf 'Thruk lab: running\n'
  printf 'API: %s\n' "$endpoint"
  printf 'Web: %s\n' "${endpoint%/thruk/r/v1}/"
  printf 'Basic user: omdadmin\n'
  printf 'Basic password: %s\n' "$basic_password"
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
    printf 'Thruk lab stopped.\n'
    ;;
  status)
    print_status
    ;;
  api-key)
    if ! docker_command container inspect "$container_name" >/dev/null 2>&1; then
      printf 'Thruk lab is stopped.\n' >&2
      exit 1
    fi
    docker_command exec "$container_name" cat /omd/sites/demo/var/thruk/secret.key
    ;;
  api-test)
    trap cleanup_lab EXIT HUP INT TERM
    start_lab
    verify_api
    printf 'Thruk REST API integration passed.\n'
    ;;
  test)
    require_command swift
    trap cleanup_lab EXIT HUP INT TERM
    start_lab
    verify_api
    ISSUELIGHT_LIVE_THRUK_URL=$endpoint \
      ISSUELIGHT_THRUK_BASIC_PASSWORD=$basic_password \
      ISSUELIGHT_THRUK_API_KEY=$api_key \
      swift test \
        --package-path "$repository_root/Packages/IssueLightCore" \
        --filter ThrukLiveConnectionTests
    printf 'Thruk provider integration passed.\n'
    ;;
  *)
    printf 'Usage: %s {start|stop|status|api-key|api-test|test}\n' "$0" >&2
    exit 64
    ;;
esac
