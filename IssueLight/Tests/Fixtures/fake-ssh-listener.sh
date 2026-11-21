#!/bin/sh

set -eu

forward=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -D|-L)
            forward="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

test -n "$forward"
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
