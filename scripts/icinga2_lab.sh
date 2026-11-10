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
: "${ISSUELIGHT_ICINGA_ARTIFACTS_DIR:?missing in .env.local}"

compose() {
  docker compose --project-directory "$LAB_DIR" --env-file "$ENV_FILE" -f "$LAB_DIR/compose.yaml" "$@"
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
  docker cp "$container_id:/data/var/lib/icinga2/certs/issuelight-live-client/issuelight-live-client.p12" "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/issuelight-live-client.p12" >/dev/null
  docker cp "$container_id:/data/var/lib/icinga2/certs/issuelight-live-rejected/issuelight-live-rejected.p12" "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/issuelight-live-rejected.p12" >/dev/null
  chmod 600 "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/issuelight-live-client.p12"
  chmod 600 "$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/issuelight-live-rejected.p12"
}

verify_swift_mtls() {
  ISSUELIGHT_LIVE_ICINGA_URL="https://localhost:$ISSUELIGHT_ICINGA_PORT" \
  ISSUELIGHT_LIVE_ICINGA_PKCS12_PATH="$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/issuelight-live-client.p12" \
  ISSUELIGHT_LIVE_ICINGA_REJECTED_PKCS12_PATH="$ISSUELIGHT_ICINGA_ARTIFACTS_DIR/issuelight-live-rejected.p12" \
    swift test \
      --package-path "$ROOT_DIR/Packages/IssueLightCore" \
      --filter Icinga2LiveConnectionTests
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

  printf 'Icinga 2 integration matrix passed.\n'
}

case "${1:-}" in
  start)
    compose up -d
    wait_for_api
    generate_client_identity
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
