#!/bin/sh
set -eu

mkdir -p /home/operator/.ssh
cp /run/issuelight/authorized_key /home/operator/.ssh/authorized_keys
chown -R operator:operator /home/operator/.ssh
chmod 700 /home/operator/.ssh
chmod 600 /home/operator/.ssh/authorized_keys

darkhttpd /srv/http --addr 127.0.0.1 --port 8080 &
exec /usr/sbin/sshd -D -e
