#!/bin/sh

set -eu

forward=""
ssh_port=22
bastion_host=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -D|-L)
            forward="$2"
            shift 2
            ;;
        -p)
            ssh_port="$2"
            shift 2
            ;;
        --)
            bastion_host="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

test -n "$forward"
test -n "$bastion_host"
if [ "$ssh_port" -ne 22 ] || [ "$bastion_host" = "always-fail.example.test" ]; then
    echo "ssh: connect to host bastion.example.test port $ssh_port: Operation timed out" >&2
    exit 255
fi

case "$forward" in
    127.0.0.1:*:*)
        destination=${forward#*:}
        port=${destination%%:*}
        ;;
    *)
        port=${forward##*:}
        ;;
esac
exec /usr/bin/nc -l 127.0.0.1 "$port"
