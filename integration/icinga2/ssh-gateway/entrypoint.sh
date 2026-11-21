#!/bin/sh
set -eu

case "$ISSUELIGHT_SSH_PUBLIC_KEY" in
  'ssh-ed25519 '*) ;;
  *)
    printf 'Missing generated SSH fixture public key.\n' >&2
    exit 2
    ;;
esac

mkdir -p /home/operator/.ssh
printf '%s\n' "$ISSUELIGHT_SSH_PUBLIC_KEY" > /home/operator/.ssh/authorized_keys
chown -R operator:operator /home/operator/.ssh
chmod 700 /home/operator/.ssh
chmod 600 /home/operator/.ssh/authorized_keys

darkhttpd /srv/http --addr 127.0.0.1 --port 8080 &
socat TCP-LISTEN:5665,bind=127.0.0.1,reuseaddr,fork TCP:icinga2:5665 &
socat TCP-LISTEN:25666,bind=127.0.0.1,reuseaddr,fork TCP:icinga2:5665 &
socat TCP-LISTEN:28081,bind=127.0.0.1,reuseaddr,fork TCP:web-gateway:8081 &
exec /usr/sbin/sshd -D -e
