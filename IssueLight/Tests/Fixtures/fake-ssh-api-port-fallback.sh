#!/bin/sh

set -eu

forward=""
ssh_port=22
while [ "$#" -gt 0 ]; do
    case "$1" in
        -D)
            forward="$2"
            shift 2
            ;;
        -p)
            ssh_port="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

test -n "$forward"
if [ "$ssh_port" -ne 22 ]; then
    echo "ssh: connect to host bastion.example.test port $ssh_port: Operation timed out" >&2
    exit 255
fi

port=${forward##*:}
exec /usr/bin/nc -l 127.0.0.1 "$port"
