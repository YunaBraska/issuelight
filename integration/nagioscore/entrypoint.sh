#!/bin/sh
set -eu

password=${ISSUELIGHT_NAGIOS_PASSWORD:-issuelight-live}
htpasswd -bc /usr/local/nagios/etc/htpasswd.users nagiosadmin "$password" >/dev/null
chown root:www-data /usr/local/nagios/etc/htpasswd.users
chmod 0640 /usr/local/nagios/etc/htpasswd.users

/usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg
/usr/local/nagios/bin/nagios /usr/local/nagios/etc/nagios.cfg &
nagios_pid=$!

stop_services() {
    kill "$nagios_pid" "$apache_pid" 2>/dev/null || true
    wait "$nagios_pid" "$apache_pid" 2>/dev/null || true
}
trap stop_services EXIT HUP INT TERM

apache2ctl -D FOREGROUND &
apache_pid=$!

while kill -0 "$nagios_pid" 2>/dev/null && kill -0 "$apache_pid" 2>/dev/null; do
    sleep 1
done

exit 1
