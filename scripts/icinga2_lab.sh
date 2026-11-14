#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LAB_DIR="$ROOT_DIR/integration/icinga2"
ENV_FILE="$LAB_DIR/.env.local"

if [ ! -f "$ENV_FILE" ]; then
  printf 'Missing %s. Copy .env.example and set local values.\n' "$ENV_FILE" >&2
  exit 2
fi

set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

: "${ISSUELIGHT_ICINGA_BASIC_PASSWORD:?missing in .env.local}"
: "${ISSUELIGHT_ICINGA_FORBIDDEN_PASSWORD:?missing in .env.local}"
: "${ISSUELIGHT_ICINGA_PKCS12_PASSWORD:?missing in .env.local}"
: "${ISSUELIGHT_ICINGA_PORT:=5665}"
: "${ISSUELIGHT_SSH_PORT:=2222}"
: "${ISSUELIGHT_ICINGA_ARTIFACTS_DIR:?missing in .env.local}"

compose() {
  docker compose --project-directory "$LAB_DIR" --env-file "$ENV_FILE" -f "$LAB_DIR/compose.yaml" "$@"
}

generate_ssh_fixture_identity() {
  mkdir -p "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR"
  if [ ! -f "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/ssh-tunnel" ]; then
    ssh-keygen \
      -q \
      -t ed25519 \
      -N '' \
      -C issuelight-ssh-tunnel-fixture \
      -f "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/ssh-tunnel"
  fi
  chmod 600 "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/ssh-tunnel"
  chmod 644 "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/ssh-tunnel.pub"
}

wait_for_ssh_fixture() {
  attempt=0
  while [ "$attempt" -lt 40 ]; do
    if nc -z -G 1 127.0.0.1 "$ISSUELIGHT_SSH_PORT" 2>/dev/null; then
      ssh-keyscan \
        -p "$ISSUELIGHT_SSH_PORT" \
        127.0.0.1 \
        > "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/ssh-known-hosts" 2>/dev/null
      chmod 600 "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/ssh-known-hosts"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done

  printf 'SSH tunnel fixture did not become ready.\n' >&2
  compose logs --tail 100 ssh-gateway >&2
  return 1
}

wait_for_api() {
  attempt=0
  while [ "$attempt" -lt 40 ]; do
    status=$(
      curl --silent --insecure --output /dev/null --write-out '%{http_code}' \
        --config - "https://localhost:$ISSUELIGHT_ICINGA_PORT/v1/objects/hosts?attrs=name&limit=1" <<CURL_CONFIG || true
user = "issuelight-basic:$ISSUELIGHT_ICINGA_BASIC_PASSWORD"
CURL_CONFIG
    )
    if [ "$status" = "200" ]; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done

  printf 'Icinga 2 API did not become ready.\n' >&2
  compose logs --tail 100 icinga2 >&2
  return 1
}

reschedule_fixture_checks() {
  for request_body in \
    '{"type":"Host","filter":"match(\"*-host\", host.name)","force":true}' \
    '{"type":"Service","filter":"match(\"*\", service.name)","force":true}'
  do
    response_code=$(
      curl --silent --show-error --insecure --output /dev/null --write-out '%{http_code}' \
        --request POST \
        --header 'Accept: application/json' \
        --header 'Content-Type: application/json' \
        --data "$request_body" \
        --config - "https://localhost:$ISSUELIGHT_ICINGA_PORT/v1/actions/reschedule-check" <<CURL_CONFIG
user = "issuelight-basic:$ISSUELIGHT_ICINGA_BASIC_PASSWORD"
CURL_CONFIG
    )
    expect_status 200 "$response_code" "fixture check reschedule"
  done
}

wait_for_fixture() {
  attempt=0
  while [ "$attempt" -lt 20 ]; do
    hosts=$(
      curl --silent --show-error --insecure --config - \
        "https://localhost:$ISSUELIGHT_ICINGA_PORT/v1/objects/hosts?attrs=name&attrs=state" <<CURL_CONFIG
user = "issuelight-basic:$ISSUELIGHT_ICINGA_BASIC_PASSWORD"
CURL_CONFIG
    )
    services=$(
      curl --silent --show-error --insecure --config - \
        "https://localhost:$ISSUELIGHT_ICINGA_PORT/v1/objects/services?attrs=name&attrs=host_name&attrs=state" <<CURL_CONFIG
user = "issuelight-basic:$ISSUELIGHT_ICINGA_BASIC_PASSWORD"
CURL_CONFIG
    )
    if printf '%s' "$hosts" | grep -F '"name":"healthy-host","state":0' >/dev/null \
      && printf '%s' "$hosts" | grep -F '"name":"down-host","state":1' >/dev/null \
      && printf '%s' "$services" | grep -F '"host_name":"healthy-host","name":"healthy-service","state":0' >/dev/null \
      && printf '%s' "$services" | grep -F '"host_name":"down-host","name":"cascaded-service","state":2' >/dev/null
    then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done

  printf 'Icinga 2 fixture checks did not reach their expected states.\n' >&2
  return 1
}

generate_server_identity() {
  # Icinga's generated leaf lacks the serverAuth EKU required by Apple's SSL policy.
  # shellcheck disable=SC2016
  compose exec -T icinga2 sh -ceu '
    cert_dir=/data/var/lib/icinga2/certs
    ca_dir=/data/var/lib/icinga2/ca
    openssl req -new -newkey rsa:2048 -nodes \
      -keyout "$cert_dir/localhost.key.new" \
      -out "$cert_dir/localhost.csr.new" \
      -subj /CN=localhost 2>/dev/null
    openssl x509 -req \
      -in "$cert_dir/localhost.csr.new" \
      -CA "$ca_dir/ca.crt" \
      -CAkey "$ca_dir/ca.key" \
      -CAcreateserial \
      -days 365 \
      -sha256 \
      -out "$cert_dir/localhost.crt.new" \
      -extfile /dev/stdin 2>/dev/null <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost
EOF
    mv "$cert_dir/localhost.key.new" "$cert_dir/localhost.key"
    mv "$cert_dir/localhost.csr.new" "$cert_dir/localhost.csr"
    mv "$cert_dir/localhost.crt.new" "$cert_dir/localhost.crt"
    chown icinga:icinga \
      "$cert_dir/localhost.key" \
      "$cert_dir/localhost.csr" \
      "$cert_dir/localhost.crt"
    chmod 600 "$cert_dir/localhost.key"
  '
  compose restart icinga2 >/dev/null
  wait_for_api
}

generate_client_identity() {
  # The quoted script expands inside the container, not in this shell.
  # shellcheck disable=SC2016
  compose exec -T icinga2 sh -ceu '
    create_identity() {
      file_name=$1
      common_name=$2
      cert_dir="/data/var/lib/icinga2/certs/$file_name"
      mkdir -p "$cert_dir"
      if [ ! -f "$cert_dir/$file_name.crt" ]; then
        icinga2 pki new-cert \
          --cn "$common_name" \
          --key "$cert_dir/$file_name.key" \
          --csr "$cert_dir/$file_name.csr"
        icinga2 pki sign-csr \
          --csr "$cert_dir/$file_name.csr" \
          --cert "$cert_dir/$file_name.crt"
      fi
      openssl pkcs12 -export \
        -inkey "$cert_dir/$file_name.key" \
        -in "$cert_dir/$file_name.crt" \
        -out "$cert_dir/$file_name.p12" \
        -passout env:ISSUELIGHT_ICINGA_PKCS12_PASSWORD
    }

    create_identity issuelight-live-client issuelight-live-client.issuelight.invalid
    create_identity issuelight-live-rejected issuelight-live-rejected.issuelight.invalid
  '

  mkdir -p "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR"
  container_id=$(compose ps -q icinga2)
  docker cp "$container_id:/data/var/lib/icinga2/certs/ca.crt" "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/ca.crt" >/dev/null
  docker cp "$container_id:/data/var/lib/icinga2/certs/localhost.crt" "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/server.crt" >/dev/null
  docker cp "$container_id:/data/var/lib/icinga2/certs/issuelight-live-client/issuelight-live-client.p12" "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/issuelight-live-client.p12" >/dev/null
  docker cp "$container_id:/data/var/lib/icinga2/certs/issuelight-live-rejected/issuelight-live-rejected.p12" "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/issuelight-live-rejected.p12" >/dev/null
  chmod 600 "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/issuelight-live-client.p12"
  chmod 600 "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/issuelight-live-rejected.p12"
}

verify_swift_mtls() {
  ISSUELIGHT_LIVE_ICINGA_URL="https://localhost:$ISSUELIGHT_ICINGA_PORT" \
  ISSUELIGHT_LIVE_ICINGA_CA_PATH="$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/ca.crt" \
  ISSUELIGHT_LIVE_ICINGA_SERVER_CERT_PATH="$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/server.crt" \
  ISSUELIGHT_LIVE_ICINGA_PKCS12_PATH="$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/issuelight-live-client.p12" \
  ISSUELIGHT_LIVE_ICINGA_REJECTED_PKCS12_PATH="$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/issuelight-live-rejected.p12" \
    swift test \
      --package-path "$ROOT_DIR/Packages/IssueLightCore" \
      --filter Icinga2LiveConnectionTests
}

verify_app_model_multi_source() {
  live_model_derived_data=$(mktemp -d "${TMPDIR:-/tmp}/issuelight-live-model.XXXXXX")
  trap 'rm -rf "$live_model_derived_data"' EXIT HUP INT TERM
  xcodebuild build-for-testing \
    -project "$ROOT_DIR/IssueLight/IssueLight.xcodeproj" \
    -scheme IssueLight \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$live_model_derived_data" \
    CODE_SIGNING_ALLOWED=NO
  ISSUELIGHT_LIVE_ICINGA_URL="https://localhost:$ISSUELIGHT_ICINGA_PORT" \
  ISSUELIGHT_REQUIRE_LIVE_ICINGA=1 \
  ISSUELIGHT_ICINGA_BASIC_PASSWORD="$ISSUELIGHT_ICINGA_BASIC_PASSWORD" \
  ISSUELIGHT_LIVE_ICINGA_CA_PATH="$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/ca.crt" \
  ISSUELIGHT_REQUIRE_LIVE_SSH=1 \
  ISSUELIGHT_LIVE_SSH_PORT="$ISSUELIGHT_SSH_PORT" \
  ISSUELIGHT_LIVE_SSH_KEY_PATH="$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/ssh-tunnel" \
  ISSUELIGHT_LIVE_SSH_KNOWN_HOSTS_PATH="$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/ssh-known-hosts" \
    xcrun xctest \
      "$live_model_derived_data/Build/Products/Debug/IssueLightModelTests.xctest"
  rm -rf "$live_model_derived_data"
  trap - EXIT HUP INT TERM
}

request_status() {
  account=$1
  password=$2
  curl --silent --show-error --insecure --output /dev/null --write-out '%{http_code}' \
    --config - "https://localhost:$ISSUELIGHT_ICINGA_PORT/v1/objects/hosts?attrs=name&limit=1" <<CURL_CONFIG
user = "$account:$password"
CURL_CONFIG
}

expect_status() {
  expected=$1
  actual=$2
  label=$3
  if [ "$actual" != "$expected" ]; then
    printf '%s: expected HTTP %s, got %s\n' "$label" "$expected" "$actual" >&2
    return 1
  fi
  printf '%s: HTTP %s\n' "$label" "$actual"
}

verify_matrix() {
  wait_for_api

  if curl --silent --output /dev/null \
    "http://localhost:$ISSUELIGHT_ICINGA_PORT/v1/objects/hosts?attrs=name&limit=1" 2>/dev/null; then
    printf 'plain HTTP: expected transport rejection\n' >&2
    return 1
  fi
  printf 'plain HTTP: rejected\n'

  no_auth=$(curl --silent --show-error --insecure --output /dev/null --write-out '%{http_code}' \
    "https://localhost:$ISSUELIGHT_ICINGA_PORT/v1/objects/hosts?attrs=name&limit=1")
  expect_status 401 "$no_auth" "no authentication"

  basic=$(request_status issuelight-basic "$ISSUELIGHT_ICINGA_BASIC_PASSWORD")
  expect_status 200 "$basic" "basic authentication"

  wrong=$(request_status issuelight-basic wrong-local-password)
  expect_status 401 "$wrong" "wrong password"

  forbidden=$(request_status issuelight-forbidden "$ISSUELIGHT_ICINGA_FORBIDDEN_PASSWORD")
  expect_status 403 "$forbidden" "missing permission"

  if curl --silent --output /dev/null --config - \
    "https://localhost:$ISSUELIGHT_ICINGA_PORT/v1/objects/hosts?attrs=name&limit=1" 2>/dev/null <<CURL_CONFIG
user = "issuelight-basic:$ISSUELIGHT_ICINGA_BASIC_PASSWORD"
CURL_CONFIG
  then
    printf 'untrusted private CA: expected TLS rejection\n' >&2
    return 1
  fi
  printf 'untrusted private CA: rejected\n'

  trusted=$(curl --silent --show-error --cacert "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/ca.crt" \
    --output /dev/null --write-out '%{http_code}' --config - \
    "https://localhost:$ISSUELIGHT_ICINGA_PORT/v1/objects/hosts?attrs=name&limit=1" <<CURL_CONFIG
user = "issuelight-basic:$ISSUELIGHT_ICINGA_BASIC_PASSWORD"
CURL_CONFIG
  )
  expect_status 200 "$trusted" "private CA trust"

  mtls=$(curl --silent --show-error --insecure --output /dev/null --write-out '%{http_code}' \
    --cert-type P12 --cert "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/issuelight-live-client.p12:$ISSUELIGHT_ICINGA_PKCS12_PASSWORD" \
    "https://localhost:$ISSUELIGHT_ICINGA_PORT/v1/objects/hosts?attrs=name&limit=1")
  expect_status 200 "$mtls" "client certificate"

  verify_swift_mtls
  verify_app_model_multi_source

  printf 'Icinga 2 integration matrix passed.\n'
}

case "${1:-}" in
  start)
    generate_ssh_fixture_identity
    compose up -d --build
    wait_for_api
    wait_for_ssh_fixture
    generate_server_identity
    generate_client_identity
    reschedule_fixture_checks
    wait_for_fixture
    printf 'Icinga 2 lab is ready on https://localhost:%s.\n' "$ISSUELIGHT_ICINGA_PORT"
    ;;
  verify)
    verify_matrix
    ;;
  status)
    compose ps
    ;;
  stop)
    compose down
    ;;
  clean)
    compose down --volumes
    ;;
  *)
    printf 'Usage: %s {start|verify|status|stop|clean}\n' "$0" >&2
    exit 2
    ;;
esac
