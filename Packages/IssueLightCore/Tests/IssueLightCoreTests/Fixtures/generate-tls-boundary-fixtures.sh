#!/bin/sh
set -eu

output_dir=${1:?output directory is required}
openssl_bin=${OPENSSL_BIN:-openssl}

mkdir -p "$output_dir/newcerts"
: > "$output_dir/index.txt"
printf '1000\n' > "$output_dir/serial"

cat > "$output_dir/openssl.cnf" <<CONFIG
[ ca ]
default_ca = local_ca

[ local_ca ]
database = $output_dir/index.txt
serial = $output_dir/serial
new_certs_dir = $output_dir/newcerts
certificate = $output_dir/root.crt
private_key = $output_dir/root.key
default_md = sha256
default_days = 3650
policy = supplied_name
email_in_dn = no
unique_subject = no
copy_extensions = none

[ supplied_name ]
commonName = supplied

[ req ]
prompt = no
distinguished_name = request_name

[ request_name ]
CN = IssueLight TLS boundary fixture

[ root_extensions ]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always

[ server_extensions ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[ client_only_extensions ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectAltName = DNS:localhost
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
CONFIG

"$openssl_bin" req -new -x509 -nodes -newkey rsa:2048 \
  -config "$output_dir/openssl.cnf" \
  -extensions root_extensions \
  -subj '/CN=IssueLight TLS Boundary Root' \
  -days 3650 \
  -keyout "$output_dir/root.key" \
  -out "$output_dir/root.crt" >/dev/null 2>&1

"$openssl_bin" genpkey -algorithm RSA \
  -pkeyopt rsa_keygen_bits:2048 \
  -out "$output_dir/server.key" >/dev/null 2>&1

create_server_certificate() {
  certificate_name=$1
  common_name=$2
  shift 2
  "$openssl_bin" req -new \
    -config "$output_dir/openssl.cnf" \
    -subj "/CN=$common_name" \
    -key "$output_dir/server.key" \
    -out "$output_dir/$certificate_name.csr" >/dev/null 2>&1
  "$openssl_bin" ca -batch -notext \
    -config "$output_dir/openssl.cnf" \
    -extensions server_extensions \
    -in "$output_dir/$certificate_name.csr" \
    -out "$output_dir/$certificate_name.crt" \
    "$@" >/dev/null 2>&1
}

create_server_certificate valid localhost -days 3650
create_server_certificate expired expired.localhost \
  -startdate 20200101000000Z -enddate 20210101000000Z
create_server_certificate future future.localhost \
  -startdate 20400101000000Z -enddate 20410101000000Z

"$openssl_bin" req -new \
  -config "$output_dir/openssl.cnf" \
  -subj '/CN=client-only.localhost' \
  -key "$output_dir/server.key" \
  -out "$output_dir/client-only.csr" >/dev/null 2>&1
"$openssl_bin" ca -batch -notext \
  -config "$output_dir/openssl.cnf" \
  -extensions client_only_extensions \
  -in "$output_dir/client-only.csr" \
  -out "$output_dir/client-only.crt" \
  -days 3650 >/dev/null 2>&1
